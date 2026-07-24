# 03 — First boot: expand-to-fill, then add a frontend

The image ships a tiny 64 MiB empty data partition (p7) and **no frontend**. On the
first boot p7 is grown to fill the whole card and left empty; the user then copies a
frontend onto it. Every subsequent boot skips the expansion.

## 1. Why reformat instead of resize-in-place

In-place FAT32 growth would need `fatresize` (which pulls in libparted — no viable
static build) or a hand-rolled cluster-relocation defrag (complex, corruption-prone).
Since Base OS bakes no payload, the far simpler path is safe:

- ship p7 **small and empty**;
- on first boot, **grow the FAT partition's GPT entry to fill the card and give it a fresh, empty
  FAT32 at full size**.

Reformatting an empty partition can't lose data, so this needs no staging. It also
keeps the flashable image tiny (p7 is small in the image). BusyBox already ships
`mkfs.vfat`/`partprobe`/`blockdev`, so no extra tools are needed.

## 2. `gptgrow` — GPT growth + kernel live-resize (`tools/gptgrow.c`)

A zero-dependency static C tool: `gptgrow /dev/mmcblk0`.

1. reads the primary GPT, finds the highest-numbered non-empty partition (p7);
2. if it already reaches `last_usable` → **exit 1** (idempotent no-op);
3. else sets its ending LBA to `total-4`, rewrites **both** GPT headers + entry tables
   (inline CRC32) and the protective MBR; `fsync`; → **exit 0**;
4. **`ioctl(fd, BLKPG, BLKPG_RESIZE_PARTITION)`** to live-resize p7 in the kernel.

Step 4 is essential: a full partition-table reread (`partprobe`) **fails with EBUSY**
because the rootfs (p5) is mounted on the same disk. `BLKPG_RESIZE_PARTITION` updates
just p7's size in the kernel while its siblings stay mounted, so `/dev/mmcblk0p7`
reflects the new size immediately — no reread needed. (Run against a plain file, the
ioctl fails `ENOTTY` and is skipped; the GPT is still rewritten — that's the offline
test path.)

Verified offline on a simulated 20 GB card: both GPT copies come out with valid
signatures and CRCs, p7 fills the disk, idempotent on re-run. Verified on hardware:
p7 grew from 68 MB to **62.8 GB** on a 64 GB card.

## 3. `expand-storage` — the first-boot orchestrator (`overlay/usr/sbin/expand-storage`)

Runs from `rcS`, **before** the card is mounted:

1. run `gptgrow /dev/mmcblk0` (grow + BLKPG). **Its exit code is the idempotency key:**
   - **exit 1** (already fills the disk, i.e. an already-set-up card) → log and exit,
     leaving p7 completely untouched and showing no expansion message. So a frontend
     the user has copied on is never reformatted;
   - **exit 2** (GPT/device error) → log the failure, leave p7 untouched and fail;
   - **exit 0** (freshly grown) → continue;
2. paint `fbsplash 45 "EXPANDING STORAGE"` now that a real resize is confirmed;
3. fallback `partprobe`/`blockdev --rereadpt` (harmless EBUSY if BLKPG already did it);
4. `mkfs.vfat -F 32 -n BASEOS /dev/mmcblk0p7` (fresh empty FAT32, full size);
5. mount p7 and drop `README.txt` (from `/usr/share/baseos/card-readme.txt`) explaining
   how to add a frontend; `sync`; unmount.

It logs to `/tmp/expand.log` **and** mirrors to `/data/expand.log` (persistent, on p6)
so a failed expand is diagnosable after a power-off even without network. Keying
idempotency on "does p7 already fill the disk" (rather than a `/data` flag or content
check) is robust: expansion happens exactly once, and once done the partition is never
touched again.

## 4. Adding a frontend (the hand-off)

Base OS ships no frontend, so after the first-boot expansion the card is empty and
`nextui-session` shows **`ADD FRONTEND TO SD CARD`** and waits (init respawns it). The
user then:

1. mounts the card on a computer — it now presents the full-capacity `BASEOS` volume
   with the `README.txt`;
2. copies a frontend onto it — for NextUI, `MinUI.zip` (+ any `nextui.*.pakz`);
3. reboots the handheld.

On that boot `nextui-session` sees `MinUI.zip` and runs the frontend's **own**
installer (which extracts `.system/…`, processes the `*.pakz`, and creates
Bios/Roms/Saves), then launches it. The install takes ~1 min (SD-speed dependent) and
shows a static `INSTALLING FRONTEND` pill — see [04](04-boot-splash.md) for why it's static and
why the frontend's own installer UI can't render on Base OS. Every boot after that goes
straight to the frontend.

A different frontend just needs a compatible launch payload; the OS↔frontend contract
is small (a launch entry point on the card, `/mnt/SDCARD`, the poweroff/reboot
sentinels, a ready `wlan0`).

## 5. Boot-to-boot behaviour

| boot | expand-storage | frontend | net |
|---|---|---|---|
| 1st (fresh flash) | grows + reformats p7 empty (~seconds) | none yet → add-frontend prompt | expand, then wait |
| after user copies a frontend | p7 already fills disk → no-op | frontend installer runs (~1 min), then launches | slow, one-time |
| every later boot | no-op | `MinUI.zip`/pakz consumed → launch only | a few seconds to the frontend |

## 6. Edge cases & caveats

- If the card is *exactly* the image size (no free space), `gptgrow` is a no-op and p7
  stays 64 MB — realistically never (cards are always larger than the ~0.9 GB image).
- Because p7 is reformatted on first boot, the user must add the frontend **after** the
  first boot, not before — anything dropped on the tiny empty p7 pre-boot is erased by
  the expansion. (Standard handheld flow: flash → boot to expand → add content.)
