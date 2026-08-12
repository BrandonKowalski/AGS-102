# Base OS diagnostics

## sleep-drain — measure suspend battery drain

Distinguishes real deep sleep (µA-level, days of standby) from fake sleep
(tens of mA, hours) and quantifies it, using the AXP2202 hardware coulomb
counter sampled at the exact suspend/resume boundary via NextUI's hook system.

Install onto a running device's card:

```sh
D=/mnt/sdcard/.userdata/h700/.hooks
mkdir -p $D/pre-sleep.d $D/post-resume.d
cp sleep-drain/pre-sleep.d/10-drain.sh   $D/pre-sleep.d/
cp sleep-drain/post-resume.d/10-drain.sh $D/post-resume.d/
chmod 755 $D/pre-sleep.d/10-drain.sh $D/post-resume.d/10-drain.sh
```

Then sleep the device (tap power), leave it suspended for a while (30 min
minimum for a coarse read; longer or overnight for precision), wake it (tap
power). Each wake appends a line to `/mnt/sdcard/sleep-drain.log`:

```
2026-07-19 15:40:02 slept=1834s dQ=2000uAh cap=61%->61% avg=3926uA proj_suspend_life=815h
```

`avg` is the mean current during suspend; `proj_suspend_life` = full battery /
avg current. Single-digit-mA average ⇒ real deep sleep; tens of mA ⇒ fake.

## Phase 0 — the AGS-102 measurement pass

Answers whether the device really powers off, really suspends, how the lid
reports itself, and what U-Boot does — on unmodified BaseOS 1.1.0, with no
image changes. Everything below goes on the FAT card.

### Install

With the card in a computer, where `SD` is its mount point and `PAK` is the
frontend's pak directory (`$SD/.system/h700/paks/MinUI.pak` for both NextUI and
a slot card built by `task dist:device`):

```sh
mkdir -p "$SD/System"
cp diagnostics/power-sampler/ags-sample "$SD/System/"
cp diagnostics/probe/ags-probe          "$SD/System/"
chmod 755 "$SD/System/ags-sample" "$SD/System/ags-probe"

mv "$PAK/launch.sh" "$PAK/launch.real.sh"
cp diagnostics/power-sampler/launch-wrapper.sh "$PAK/launch.sh"
chmod 755 "$PAK/launch.sh"
```

### Run

Boot the device once with the cable connected, so `ags-probe.txt` is written and
adb is available. Then unplug, use it normally for a few minutes, and power it
off the way you normally would. Leave it overnight. Boot it again the next
morning — the first thing the sampler does on that boot is stamp the far side of
the gap.

### Read

```sh
python3 diagnostics/power-sampler/ags-analyse.py /path/to/card/ags-power.csv
```

A `power-cycle` gap at hundreds of milliamps means the device never powered off:
`pm_power_off` is unset and the SoC has been sitting in a halt loop with the
rails up. A `suspend` gap at hundreds of microamps is real suspend-to-RAM.

Record the answers in `diagnostics/results/2026-08-12-phase-0.md`.

### Uninstall

Move `launch.real.sh` back over `launch.sh`. The CSV and probe dump can stay;
they are small and they are the evidence.
