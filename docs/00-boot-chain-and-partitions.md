# 00 — Boot chain & partitions (the immutable half)

Everything in this file comes from the target's prepared StockMod firmware image.
It is the part we cannot rebuild and the part that gives "perfect hardware support";
BaseOS keeps it byte-for-byte except for the bootlogo inside p2 and regenerated GPT
metadata needed for the smaller output image.
All facts verified live on the RG40XXV (stock firmware V1.1.1.0, kernel
`4.9.170 #16 SMP PREEMPT` built 2026-05-21) on 2026-07-19.

## 1. GPT / partition layout

The stock card is **GPT** (not MBR). The RG40XXV StockMod `BASE` archive retains the
same primary GPT and partitions 1–7, but deliberately ends after p7 with entry 8 empty
and no backup GPT. `prepare-stock.sh` recognizes that exact compact form; image
composition writes valid primary and backup GPTs, restoring the known `primary`
identity into the BaseOS table:

BaseOS ships **seven** partitions, not the stock eight: `appfs` is dropped and the
region it occupied becomes the unallocated second rootfs slot (see
[07](07-partition-layout-and-updates.md)). Every partition except the user-visible
FAT volume carries GPT attribute bits 62 and 63, so a desktop assigns exactly one
drive letter for the whole card.

| # | name | start LBA | size (stock) | contents | our image |
|---|---|---|---|---|---|
| — | (gap) | 0–73727 | 36 MiB | protective MBR, primary GPT, **boot0 + U-Boot blobs** | verbatim |
| 1 | `special` | 73728 | 64 MiB | vendor special (an almost-empty ext4) | verbatim, hidden |
| 2 | `boot-resource` | 204800 | 32 MiB | **vfat**: `bootlogo.bmp`, `fastbootlogo.bmp`, fonts, DTBs | verbatim except `bootlogo.bmp` ([04](04-boot-splash.md)), hidden |
| 3 | `env` | 270336 | 16 MiB | U-Boot environment (bootargs) | verbatim, hidden |
| 4 | `boot` | 303104 | 64 MiB | **Android boot image**: kernel + vendor initramfs | verbatim, hidden |
| 5 | `rootfs` | **434176 or 1482752** | 7 GiB stock | Ubuntu 22.04 (4.1 GB used) | **the active 512 MiB slot**, hidden |
| — | *(slot B)* | 1482752 or 434176 | — | — | **512 MiB unallocated — the update target** |
| 6 | `UDISK` | 2531328 | 512 MiB stock | stock scratch/swap | **128 MiB ext4 — `/data` persistent state**, hidden |
| 7 | `primary` | 2793472 | rest | vfat ROMs partition | **64 MiB empty FAT32 — grown to fill the card on first boot; the only visible volume** |
| 8 | *(empty)* | — | — | — | — |

`UDISK` and `primary` keep the stock entries' names, type GUIDs and unique GUIDs —
they are *shifted* down one slot, not renamed.

**Load-bearing constraints** (violating any of these bricks the boot):

- U-Boot builds the kernel cmdline's `partitions=` map **from the GPT partition
  names** — verified on hardware: p3 stores `partitions=${partitions}` unexpanded and
  `/proc/cmdline` shows it expanded to exactly the GPT names. `bootcmd` boots the
  partition *named* `boot` via `sunxi_flash`. So the partition **names and order are
  load-bearing**.
- `root=/dev/mmcblk0p5` (from `mmc_root` in the env, which BaseOS never modifies)
  names a partition **number, not an address**. Nothing in boot0, U-Boot or the env
  references p5's start LBA, so partition 5 may live anywhere — which is exactly what
  makes A/B slot switching possible by rewriting the GPT alone.
- Partition **type and unique GUIDs are not known to be load-bearing** (U-Boot matches
  by name), but BaseOS preserves them anyway: they cost nothing and keep the table as
  close to stock as possible. GPT **attribute** bits are BaseOS-set and boot fine.
- `prepare-stock.sh` derives `boot-prefix.img` directly from the selected target's
  StockMod `.img`, ending exactly at p5's start. The known RG40XXV layout makes this
  **222,298,112 bytes**; other targets are read from their GPT rather than assuming
  that value. The source name/hash, geometry, prefix hash and preserved-region hashes
  are recorded in `work/<target>/source.json`. The image starts from this prefix,
  then both GPTs are regenerated for the smaller target size (see
  `tools/mkgpt.py` in [02](02-image-build-and-flash.md)).
- `bootdelay=0` already, so there's no U-Boot key-press window to shave.

### The env partition (p3) cmdline

Read raw from p3 (`dd if=/dev/mmcblk0p3 | strings`), the environment stores a
*template*, not a finished cmdline:

```
mmc_root=/dev/mmcblk0p5
setargs_mmc=setenv bootargs ... root=${mmc_root} rootwait quiet splash
            init=${init} partitions=${partitions} cma=${cma} snum=${snum} ... gpt=1
```

`partitions` is filled in by U-Boot at runtime from the GPT partition names — this is
the mechanism that makes names load-bearing and start LBAs free. On the running
handheld `/proc/cmdline` therefore reads:

```
root=/dev/mmcblk0p5 rootwait quiet splash init=/init
partitions=special@mmcblk0p1:...:rootfs@mmcblk0p5:UDISK@mmcblk0p6:primary@mmcblk0p7
console=ttyS0,115200 loglevel=4 cma=64M ... gpt=1 lcd_type=boe
```

We never modify p3. `quiet` suppresses kernel log spam; to debug boot, one can
temporarily remove it, but the image build never touches p3.

## 2. The hidden vendor initramfs (p4 is an Android boot image)

**This is the single most important and least obvious fact.** Partition 4 (`boot`)
is **not** a bare kernel — it is an **Android boot image** (`ANDROID!` magic) that
bundles the kernel **and a vendor initramfs**. Extracting it (2 KiB page size; kernel
then gzip'd ramdisk) reveals a small BusyBox-1.22 (2015) initramfs whose `/init`:

1. parses `root=` / `gpt=` / `console=` from `/proc/cmdline`;
2. runs `e2fsck -y` on the root device;
3. **mounts root with `-o rw,noatime,nodiratime,norelatime,noauto_da_alloc,barrier=0,data=ordered`**;
4. `mount --move /dev` and `exec switch_root /mnt /init`.

Two consequences drove real bugs (see [06](06-status-and-lessons.md)):

- **The root ext4 MUST have a journal.** The initramfs mounts with `data=ordered`,
  and the kernel *rejects* that on a journal-less filesystem
  (`EXT4-fs: can't mount with data=, fs mounted w/o journal`) — an eternal boot
  splash. So `mke2fs` for p5 must **not** pass `^has_journal`.
- **Our `/init` must be a regular file, not a symlink.** The 2015 `switch_root`
  chokes on our `/init → sbin/init → busybox` symlink chain (stock's single-hop
  symlink works; the exact difference is unproven). We ship `/init` as a real
  script that `exec`s BusyBox init (see [01](01-rootfs-and-init.md)).

The vendor initramfs mounts root **read-write** (not read-only). We do not currently
remount it `ro` — see the read-only-hardening item in [06](06-status-and-lessons.md).

## 3. ext4 feature policy for the 4.9 BSP kernel

The vendor kernel is 4.9.170. Modern `mke2fs` (e2fsprogs 1.47) enables features it
cannot mount. Both of our ext4 partitions — the rootfs slots and `UDISK` — are
created with:

```
-O ^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file
```

i.e. the classic feature set (`ext_attr resize_inode dir_index filetype extent
flex_bg sparse_super large_file huge_file dir_nlink extra_isize`) **plus a journal**.
`metadata_csum` needs kernel crc32c the vendor kernel lacks; `64bit`/`orphan_file`
are similarly too new. Getting this wrong is invisible until you flash — the kernel
just fails to mount root and hangs on the splash.

Kernel config points confirmed from `/proc/config.gz` on the device:

- `CONFIG_DEVTMPFS=y` but `CONFIG_DEVTMPFS_MOUNT` is **not** set → we mount devtmpfs
  ourselves in `rcS`, and bake static `/dev/console` + `/dev/null` nodes as a cover.
- `CONFIG_FRAMEBUFFER_CONSOLE` is **not** set → no kernel text console on the LCD, so
  boot debugging can't rely on printk-on-panel; we use on-screen `fbsplash`
  breadcrumbs and `/data` logs instead (see [06](06-status-and-lessons.md)).
- exfat, squashfs, overlay, f2fs, loop are **built in** — this 2026 kernel has native
  exfat (correcting earlier port notes).

## 4. Kernel modules

Only **three** modules are loaded by the running system; everything else (disp2,
audiocodec, evdev inputs, AXP2202 PMIC/battery, suspend, all filesystems) is built
into the kernel:

| module | role | notes |
|---|---|---|
| `mali_kbase.ko` | Mali-G31 GPU (`/dev/mali0`) | ~17 MB; loaded in the background during `rcS` |
| `8821cs.ko` | RTL8821CS WiFi (SDIO) | WiFi firmware embedded in the module; loaded async |
| `rtl_btlpm.ko` | RTL8821C Bluetooth low-power handshake | loaded on BT enable |

Bluetooth controller firmware lives at `/lib/firmware/rtlbt/` (`rtlbt_fw`,
`rtlbt_config`), loaded by `rtk_hciattach -n -s 115200 ttyS1 rtk_h5`.

## 5. Regenerating the GPT for a different image size

`tools/mkgpt.py` reads the primary GPT from the copied `boot-prefix.img`, keeps every
partition's name / type GUID / unique GUID and the p1–p5 start offsets, drops `appfs`
and shifts `UDISK`/`primary` down one entry, reserves the second rootfs slot as
unallocated space, sets the hidden attribute bits, and writes valid primary + backup
GPTs (correct CRCs) plus a protective MBR covering the target size. Conventions (matched exactly by `gptgrow`, [03](03-first-boot-and-expand.md)):
8 entries × 128 B at LBA 2–3, first usable LBA 4, backup entries at `total-3..-2`,
backup header at `total-1`, last usable = `total-4`. This regenerated GPT is accepted
by boot0, U-Boot **and** the kernel — validated on hardware, including on a 64 GB card
whose stale foreign backup GPT sat far past our image's end.
