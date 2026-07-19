# 03 — First boot: expand-to-fill & install

The image ships with a tiny 64 MiB empty data partition (p8). On the first boot it is
grown to fill the whole card and populated, then NextUI installs itself. Every
subsequent boot skips all of this.

## 1. Why reformat instead of resize-in-place

In-place FAT32 growth would need `fatresize` (which pulls in libparted — no viable
static build) or a hand-rolled cluster-relocation defrag (complex, corruption-prone).
The robust alternative, given BusyBox already ships `mkfs.vfat`/`partprobe`/`blockdev`:

- ship p8 **small and empty**;
- stage the release payload on the internal `appfs` partition (p6, ext4);
- on first boot, **grow p8's GPT entry to fill the card, reformat it fresh at full
  size, and copy the payload p6 → p8**.

This is corruption-safe: the payload lives on p6 until p8 is fully populated, so a
power loss mid-expand just means it re-runs. It also shrinks the flashable image (p8
no longer big in the image).

## 2. `gptgrow` — GPT growth + kernel live-resize (`tools/gptgrow.c`)

A zero-dependency static C tool: `gptgrow /dev/mmcblk0`.

1. reads the primary GPT, finds the highest-numbered partition (p8);
2. if it already reaches `last_usable` → exit 1 (idempotent no-op);
3. else sets its ending LBA to `total-4`, rewrites **both** GPT headers + entry tables
   (inline CRC32) and the protective MBR; `fsync`;
4. **`ioctl(fd, BLKPG, BLKPG_RESIZE_PARTITION)`** to live-resize p8 in the kernel.

Step 4 is essential: a full partition-table reread (`partprobe`) **fails with EBUSY**
because the rootfs (p5) is mounted on the same disk. `BLKPG_RESIZE_PARTITION` updates
just p8's size in the kernel while its siblings stay mounted, so `/dev/mmcblk0p8`
reflects the new size immediately — no reread needed. (Run against a plain file, the
ioctl fails `ENOTTY` and is skipped; the GPT is still rewritten — that's the offline
test path.)

Verified offline on a simulated 20 GB card: both GPT copies come out with valid
signatures and CRCs, p8 fills the disk, idempotent on re-run. Verified on hardware:
p8 grew from 68 MB to **62.8 GB** on a 64 GB card.

## 3. `expand-storage` — the first-boot orchestrator (`overlay/usr/sbin/expand-storage`)

Runs from `rcS`, **before** the card is mounted:

1. **provisioned check** — mount p8 `ro`; if it already contains `.system/` or
   `MinUI.zip`, unmount and exit (a no-op on every boot after the first, so it never
   touches user ROMs). This content check — rather than a `/data` flag — is robust
   across a `/data` reset.
2. paint `fbsplash 38 "EXPANDING STORAGE"`;
3. `gptgrow /dev/mmcblk0` (grow + BLKPG); fallback `partprobe`/`blockdev --rereadpt`
   (harmless EBUSY if BLKPG already did it);
4. `mkfs.vfat -F 32 -n NEXTUI /dev/mmcblk0p8` (fresh, full size);
5. paint `fbsplash 50 "COPYING SYSTEM"`; mount p6 `ro` + p8 rw; `cp -a
   /payload/. → p8`; `sync`; unmount.

It logs to `/tmp/expand.log` **and** mirrors to `/data/expand.log` (persistent, on
p7) so a failed expand is diagnosable after a power-off even without network.

## 4. The install hand-off

After `rcS`, `nextui-session` sees `MinUI.zip` (copied onto p8 by expand) and runs the
normal NextUI installer, which extracts `.system/…` and processes the `*.pakz`. This
is the same install flow as the stock-hijack path; expand just delivered the payload.
Install takes ~48 s on the tested card (SD-speed dependent). The screen shows a static
`INSTALLING` frame during it — see [04](04-boot-splash.md) for why it is static and
why NextUI's own installer UI can't render on base OS.

## 5. Boot-to-boot behaviour

| boot | expand-storage | install | net |
|---|---|---|---|
| first (fresh flash) | grows + reformats + copies payload (~seconds) | runs (~1 min) | slow, one-time |
| every later boot | provisioned check → no-op | `MinUI.zip`/pakz already consumed → skipped | a few seconds to the menu |

So a device that hit a first-boot problem generally recovers on the **next** power-on
without a reflash: expand is skipped (p8 provisioned) and there's no payload left to
re-install.

## 6. Known edge & one caveat

- If the card is *exactly* the image size (no free space), `gptgrow` is a no-op and p8
  stays 64 MB — realistically never (cards are always larger than the ~1 GB image),
  but noted.
- Because p8 ships empty and is reformatted on first boot, **users must add
  Roms/Bios/Saves after the first boot**, not before — the standard handheld flow.
  Anything dropped onto the tiny empty p8 before first boot is erased by the reformat.
