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
