# 07 — Partition layout & A/B system updates

BaseOS 1.0 ships **seven** partitions instead of the stock eight, hides all but one
of them from desktop operating systems, and updates itself by writing a spare rootfs
slot and flipping the GPT. All three come from the same observation:

> **The GPT is the only thing that selects which bytes become the root filesystem, and
> the GPT is entirely BaseOS-authored.**

Hardware-validated end to end on the RG40XXV, including a real 1.0.0 → 1.0.1 update
running the rootfs from the second slot (§8).

## 1. What this solves

1. **Updating used to mean reflashing.** A ~1 GB image write destroys the card: ROMs,
   saves, BIOS and frontend config for one-card users, and `/data` — timezone, NTP
   preference, BlueZ pairings, SSH host keys — for everyone.
2. **The card was noisy on desktops.** Users reported several Explorer windows and
   format prompts on Windows. The cause was verified on a live RG40XXV: **all eight
   stock partitions carry the Microsoft Basic Data type GUID with attributes `0`**,
   which is Windows' signal to assign a drive letter. The vendor `boot-resource`
   partition on the test device contained both `System Volume Information` and
   `.fseventsd` — Windows *and* macOS had been mounting it.

## 2. The enabling facts

Verified live on the RG40XXV, 2026-07-24:

| fact | evidence |
|---|---|
| `partitions=` is synthesised by U-Boot **from GPT names at runtime** | p3 stores `partitions=${partitions}` unexpanded; `/proc/cmdline` shows it expanded and matching the GPT names exactly |
| `root=/dev/mmcblk0p5` names a **partition number, not an address** | p3 sets `mmc_root=/dev/mmcblk0p5`; the kernel resolves it from the GPT it parses (`gpt=1`) |
| p5's start LBA is referenced by nothing | boot0 loads U-Boot from raw sectors in the pre-p1 gap; U-Boot loads the kernel from the partition *named* `boot` |
| `appfs` was dead weight | empty ext4, only `lost+found` |
| `special` carries no identity data | 64 MiB, ~6 KB non-zero, empty ext4; `mac_addr=`/`wifi_mac=`/`bt_mac=` empty on the cmdline, and `snum` equals `androidboot.serialno` (SoC-derived) |

This corrected two conservative claims in [00](00-boot-chain-and-partitions.md):
type and unique GUIDs are not load-bearing (U-Boot matches by name), and nothing pins
p5 to LBA 434176.

## 3. Layout

`SLOT_SECTORS` is 512 MiB. Slot A keeps the stock rootfs start, so a freshly flashed
card puts its root filesystem exactly where stock did.

| # | name | start LBA | sectors | role | desktop |
|---|---|---|---|---|---|
| 1 | `special` | 73728 | 131072 | vendor, verbatim | hidden |
| 2 | `boot-resource` | 204800 | 65536 | vendor vfat, bootlogo replaced | hidden |
| 3 | `env` | 270336 | 32768 | vendor, verbatim | hidden |
| 4 | `boot` | 303104 | 131072 | vendor Android boot image, verbatim | hidden |
| 5 | `rootfs` | **434176 or 1482752** | 1048576 | the active slot | hidden |
| — | *(inactive slot)* | 1482752 or 434176 | 1048576 | **unallocated** | invisible |
| 6 | `UDISK` | 2531328 | 262144 | `/data` | hidden |
| 7 | `primary` | 2793472 | grows to the card | FAT32 `BASEOS` | **the only volume** |
| 8 | *(empty)* | — | — | — | — |

Total 2,926,592 sectors = **1,498,415,104 bytes**, which zips to about **58 MB** — the
512 MiB of reserved zeros cost roughly 1 MB compressed. The rootfs uses ~100 MB of its
slot, leaving 5× headroom for PortMaster and similar later work.

`UDISK` and `primary` are **shifted, not renamed**: each keeps its stock name, type
GUID and unique GUID, and `appfs` is dropped. The inactive slot is deliberately *not*
a partition — that is what makes A/B cost zero visible partitions.

### Desktop visibility

Every entry except `primary` gets GPT attributes `0xC000000000000000` — bit 62
(hidden) and bit 63 (no drive letter). `primary` keeps attributes `0` and the Basic
Data type GUID so desktops mount it as `BASEOS`. Type GUIDs are otherwise unchanged
from stock: attribute bits achieve the same result with less deviation.

macOS honours neither bit, and `boot-resource` must stay FAT for U-Boot's bootlogo and
DTB reads, so macOS still shows two volumes. Windows is the reported complaint and the
one this targets.

## 4. Updates

### Payload

One file named `*.bosupd`, an uncompressed ustar archive containing, in order:

| member | contents |
|---|---|
| `manifest` | ASCII `key=value`, < 1 KB |
| `rootfs.img.gz` | gzip of the exact ext4 slot image `build-image.sh` writes |

```
format=baseos-update/1
target=rg40xxv
version=1.0.0
build=6f70283
slot-sectors=1048576
image-size=536870912
image-sha256=<sha256 of the decompressed image>
```

The payload decompresses to the **byte-identical** filesystem the image build
produces, so an updated device ends up indistinguishable from a freshly flashed one.
About 36 MB for a 512 MiB slot.

The extension is not `.tar` on purpose: macOS Archive Utility auto-extracts `.tar`.

**There is no signing key.** Integrity is the SHA-256 in the manifest, verified by
reading the slot back after writing, and published next to the download so users can
check their copy by hand. A signing key would be a single point of failure for every
update on every device, and these images carry no secrets.

### Applying — `overlay/usr/sbin/baseos-update`

Called from `rcS` right after the card mount. An ordinary boot costs one failed glob.
Payloads are looked for on `/mnt/sdcard` first, then on this card's own `primary`
volume if that is not already the mounted card — so it works for both the one-card and
two-card layouts.

```
1  read every *.bosupd's `manifest` via `tar -xOf`
2  format, target and slot geometry must match this device      → refuse
3  version must be newer than the running one (or the same version with a
   different build — a rebuild), and its image hash must not appear in
   /data/update/history                                          → silent no-op
3a apply the first payload that survives; if none does, do nothing
4  paint `UPDATING SYSTEM` at stage 50
5  tar -xOf … rootfs.img.gz | gunzip | dd of=/dev/mmcblk0 seek=<inactive slot>,
   in 1/16th chunks, repainting the track 50 → 80 as each chunk is fsync'd
6  read the slot back in the same chunks into one sha256sum, track 80 → 92
   → mismatch: stop, GPT untouched
7  gptslot flip                             ← the commit point
8  record the commit in /data/update/committed-sha and the trial in
   /data/update/state; sync; reboot
```

The chunking exists so the progress track can move; `iflag=fullblock` is what makes it
safe, since a short read from the pipe would otherwise leave every later chunk
misaligned. See [04](04-boot-splash.md) §5 for why a moving bar here does not
contradict the no-animation rule.

Step 7 is the only irreversible action and every check precedes it, so **power loss at
any earlier moment leaves the card byte-identical to before the update**. The running
system also keeps working across the flip: the kernel's cached partition offsets still
point at the old slot until the reboot.

The payload is never deleted — it is a user file on a user card, and users accumulate
them. That makes selection the subtle part, and two rules keep it correct:

- **Every payload is considered, not just the first.** The glob is sorted, so a stale
  `…-1.0.1.bosupd` sorts ahead of the `…-1.0.2.bosupd` next to it. Stopping at the
  first file meant the stale one — already the running build — silently absorbed the
  scan and the new one was never opened.
- **Only ever move forward.** A payload older than the running version is skipped. The
  moment you update past a leftover, it would otherwise become "applicable" again:
  downgrade, then re-apply the newer one, and ping-pong between them forever. A
  rebuild of the *running* version is still allowed, which is what makes development
  iteration work.

With several genuinely new payloads present the device applies them in filename order
over successive boots rather than jumping to the newest — predictable, and stepping
through versions in order is the safer upgrade path anyway.

`/data/update/history` — `<sha> <version> <build>` per line — is appended at **commit**
time rather than on success, and that ordering is load-bearing. If it were only written
once an update was confirmed, a payload that turns out to be broken would roll back, be
found on the card again on the very next boot, and be re-applied — oscillating forever.
Recording the commit means a rolled-back payload stays on the card but is never
retried; publishing a fixed build is what moves the device on. (To deliberately
re-apply something, delete its line from the history.)

`baseos-update status` prints every payload it can see with the verdict for each,
because the apply path is deliberately silent about the ones it skips — it runs on
every boot — and "I copied the file and nothing happened" needs an answer somewhere.

### Rollback

- `rcS` runs `baseos-update boot-check`: while a trial is open it counts boots and,
  on the third, paints `RESTORING SYSTEM`, flips back and reboots.
- `nextui-session` runs `baseos-update confirm` as it starts, which ends the trial and
  appends to `/data/update/applied.log`.

Confirming on **session start** rather than on frontend hand-off is deliberate: a card
with no frontend is a perfectly healthy OS, and keying the trial to `frontend-exec`
would make that state look like a failed update and roll back forever.

This covers a slot that boots but breaks before the session starts. It cannot cover a
rootfs so broken that `/init` never runs — nothing BaseOS controls executes earlier —
so that remains a reflash, exactly as today. Manual rollback is `gptslot /dev/mmcblk0
flip` over SSH whenever the system boots at all.

## 5. `gptslot` — the slot arithmetic

`tools/gptslot.c`, a zero-dependency static tool like `gptgrow`. Geometry is derived
from the GPT alone, with no state file to lose:

```
slot_base    = boot.end + 1
slot_sectors = rootfs.end - rootfs.start + 1
active       = A if rootfs.start == slot_base else B
```

It refuses anything that is not a BaseOS A/B layout: partition 5 must be named
`rootfs` and start at exactly one of the two halves, and partition 6 must start
exactly `2 × slot_sectors` past `slot_base`. A pre-1.0 card puts `appfs` one slot in,
so **an old card fails this check and cannot be slot-flipped** — the version guard is
the geometry itself, not a version string.

`flip` writes backup entries → backup header → primary entries → primary header, with
`fsync` between the copies. If power is lost mid-commit the primary still describes
the old slot, and every consumer here (boot0, U-Boot, the kernel) reads the primary.
Usable-LBA bounds and every other header field are left exactly as found.

`gptgrow` deliberately still carries its own copy of the CRC/read/write helpers now
also in `tools/gpt.h`: it is hardware-proven on the first-boot path and has no offline
regression test, so it is not worth refactoring for 40 shared lines.

## 6. Building and publishing an update

```sh
./build-image.sh rg40xxv
./build-update.sh rg40xxv        # -> work/rg40xxv/baseos-rg40xxv-1.0.0.bosupd
```

`build-update.sh` reads the rootfs extent from the finished image's own GPT, streams
the slot once to hash and compress it, and refuses to build unless the filesystem
carries both the `BASEOS_VERSION` and the `BASEOS_BUILD` the manifest is about to
claim. A manifest that overstates its version would otherwise be applied, boot, still
disagree with itself and be applied again. It prints the SHA-256 to publish
alongside the download.

The version comes from the repo-root `VERSION` file; `BASEOS_BUILD` is
`git describe --always --dirty`. Both are baked into `/etc/baseos-release`, and
`/etc/os-release` is generated from the same value so the two cannot drift.

## 7. Tests

| test | covers |
|---|---|
| `tests/test-gpt-slot.sh` | synthetic images: the 1.0 layout and its attributes, geometry derivation, that a flip moves only the rootfs extent, that two flips restore the card byte-for-byte, and that a pre-1.0 layout is refused |
| `tests/test-update-apply.sh` | the engine on stubs: wrong target, wrong slot size, corrupt image, no A/B layout and an already-applied payload are all refused **with the GPT untouched**; a good payload commits; a payload matching the running build is skipped (this prevents a reboot loop on the first boot after an update); a rolled-back payload is not applied again (this prevents an endless rollback/re-apply oscillation); the trial counter rolls back on the third failed boot |
| `test-update-roundtrip.sh <target>` | the real payload against a copy of the real image: the inactive slot receives exactly the payload bytes, the GPT commits, the new slot is a mountable rootfs carrying the new version, and `UDISK` and `primary` are byte-for-byte unchanged |

## 8. Hardware validation

**Confirmed on the RG40XXV (2026-07-24, BaseOS 1.0.0):**

- the seven-partition layout with hidden attribute bits boots normally, so U-Boot
  neither minds the attributes nor the dropped `appfs` and renumbering;
- NextUI starts and reports BaseOS 1.0.0;
- macOS lists seven partitions on the card;
- `baseos-update` correctly ignored a payload whose `version`/`build` matched the
  running system — the guard against re-applying on every boot works in the field.

**A real update, 1.0.0 → 1.0.1, also confirmed on the RG40XXV:**

```
 3.04 applying 1.0.1 from /mnt/sdcard/baseos-rg40xxv-1.0.1.bosupd to slot at LBA 1482752
53.70 inactive slot verified
53.72 flipped to slot 1.0.1; rebooting
 2.72 update trial boot 1 of 3
 3.06 update to 1.0.1 confirmed
```

That single run settled the design's last open assumption: the device now runs its
rootfs from **LBA 1482752**, the slot-B offset, so partition 5 really may live at
either address. It also showed `/data` surviving the flip — the log above was written
before the flip and read back after it — and the trial arming and clearing exactly as
intended.

The 50.7 s between the first and second lines was silent on screen, which is what
motivated the moving progress track ([04](04-boot-splash.md) §5).

**Payload selection, confirmed on the same device (1.0.1 → 1.0.3):** with four
payloads present — 1.0.0 on the card's own `BASEOS` volume, plus 1.0.1, 1.0.2 and
1.0.3 on the NextUI card — the engine evaluated all four across both directories,
applied 1.0.3, and afterwards reported each of the others as `skipped: not newer than
the running 1.0.3`. The pre-1.0.3 `committed-sha` file was migrated into `history`
automatically.

**Still outstanding:**

- **Windows** — the reported complaint. Expect exactly one drive letter and zero
  format prompts. If attribute bit 63 turns out not to be honoured on removable
  media, the fallback is retyping the ext4 partitions to the Linux filesystem GUID
  (`0fc63daf-8483-4772-8e79-3d69d8477de4`), which Windows ignores unconditionally.
- **A rollback on hardware.** The trial counter and restore flip pass offline but have
  never fired on a device, because no update has failed yet.
