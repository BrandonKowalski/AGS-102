# BaseOS

BaseOS is a minimal, stock-derived Linux for Anbernic RG XX handhelds using the
Allwinner H700. It replaces the stock Ubuntu userland with BusyBox init while
retaining the vendor boot chain, kernel, and hardware support—including real
suspend-to-RAM, GLES, audio, input, Wi-Fi, Bluetooth audio, and HDMI.

**[Install BaseOS](INSTALL.md)**

## ⚡ Boot duration

* **≈7.14 s** — power LED to NextUI on RG40XXV.
* **2.96 s BaseOS** — measured kernel start to frontend execution, our primary
optimization target.

Stock Anbernic + NextUI baseline: **17.5 s** (manually measured with a stopwatch).

Last change: **7.18 → 7.14 s** — static boot logo, ≈40 ms saved.

## What BaseOS provides

- A small, fast, purpose-built operating system.
- In-place updates: copy one file onto the card and reboot. No reflashing, and
  your ROMs, saves and settings are untouched.
- Fast hand-off to a frontend. NextUI is first-class today; the OS remains
  frontend-agnostic.
- First-boot expansion of the data partition to fill the SD card.
- One volume on the card when you plug it into a computer, not eight — no stray
  "format this disk?" prompts on Windows.
- Full support for the handheld's display, sound, controls, networking, HDMI, and
  real suspend-to-RAM.
- SSH/SFTP over Wi-Fi and adb over USB active by default.
- Optional USB-storage maintenance mode for the selected frontend card.

## Installation

Follow **[INSTALL.md](INSTALL.md)** for flashing, first boot, and NextUI setup on
one-card or two-card configurations.

## Supported devices

- Anbernic RG28XX
- Anbernic RG34XX
- Anbernic RG34XX SP
- Anbernic RG35XX Plus and RG35XX 2024
- Anbernic RG35XX H
- Anbernic RG35XX Pro
- Anbernic RG35XX SP
- Anbernic RG40XX H
- Anbernic RG40XX V
- Anbernic RG CubeXX

Development setup, build instructions, testing, and technical documentation are in
**[CONTRIBUTING.md](CONTRIBUTING.md)**.

## USB access

Connect a data-capable USB-C cable to use `adb shell`, `adb push`, or `adb pull`.
To expose the selected frontend card as a writable USB drive instead, create
`BaseOS.conf` at the card's root with this exact line:

```ini
USB_STORAGE=1
```

Restart the handheld. BaseOS stops the frontend, safely unmounts that card, and
offers both the USB drive and adb. This selects TF2 in a two-card setup and the
on-device data partition in a one-card setup. To return to normal, set the value
to `0` (or remove the line), safely eject the drive on the computer, and restart
the handheld.
