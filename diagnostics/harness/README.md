# Card-side test harnesses

Each of these replaces the frontend's `launch.sh` for exactly one boot. They
exist because the measurements they take cannot be driven over adb: adb needs
the USB cable, and on this hardware the cable both charges the battery (making
any drain reading meaningless) and wakes the device every 20-40s through the
`usb_connecting` wakeup source. Three attempts died that way before the work
moved onto the card.

Install by renaming the frontend's own `launch.sh` to `launch.real.sh` and
dropping one of these in its place. Each is armed by a marker file and deletes
that marker on its first run, so a forgotten install leaves a normal device
rather than one that suspends or powers off on every boot.

| script | marker | measures |
|---|---|---|
| `launch-sstest.sh`  | `ags-sstest.pending`  | suspend drain with Super Standby (`os_sleep = 16`) |
| `launch-offtest.sh` | `ags-offtest.pending` | whether `poweroff` cuts power with VBUS absent |

Both stamp the gauge and the RTC to `ags-poweroff-test.txt` on the card either
side of the event, so the result survives the device being flat, wedged, or
unreachable over adb.

Results live in `../results/`.
