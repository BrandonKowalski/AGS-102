# BaseOS

BaseOS is a minimal operating system for Anbernic RG XX handhelds.

If you're tired of slow boot times, high battery consumption, or less than ideal
support for hardware features on other custom firmwares, BaseOS is for you.

It is designed as a drop-in replacement for the stock OS.

However, BaseOS does not have a user interface of its own. It is designed to
run another existing frontend. Currently it only supports NextUI which is in
beta for Anbernic H700 devices.

**[Install BaseOS](INSTALL.md)**

## ⚡ Boot duration

* **7.14 s** — power LED to NextUI on RG40XXV.
* **2.96 s BaseOS** — measured kernel start to frontend execution, our primary
optimization target.

Stock Anbernic + NextUI baseline: **17.5 s** (manually measured with a stopwatch).

## What BaseOS provides

- The fastest possible boot time for Anbernic RG XX devices.
- Lowest possible resource and battery usage.
- Takes 5 sec to install.
- Full support for the handheld's display, sound, controls, networking, HDMI, LEDs,
  deep sleep and other features. No comporise on that front.
- First-boot expansion of the data partition to fill the SD card.
- Easy updates: copy one file onto the card and reboot. No reflashing, and
  your ROMs, saves and settings are untouched.
- SSH/SFTP over Wi-Fi and adb over USB active by default.
- USB storage mode (hold MENU when powering on).

Currently BaseOS only supports NextUI as its frontend. Additional frontends
are planned for future.

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

For reliable adb, connect a data-capable USB-C cable before powering on. If it
is disconnected, restart with the cable connected.

To access the SD card as a USB drive, connect the USB cable first, then hold
**MENU** while powering on. Keep holding it until the USB-storage message
appears. BaseOS shares the complete TF2 card when one is inserted; otherwise it
shares TF1's data partition. adb remains available.

Eject the drive on the computer before restarting the handheld. Restart without
holding MENU to return to normal.

## How does it work?

BaseOS is derived from the stock Anbernic OS for H700-based handhelds. The 
kernel, drivers, DTB etc are untouched, giving you perfect hardware support.
However, it replaces the stock Ubuntu userland with a custom BusyBox based
rootfs. We retain all required features like WiFi, GLES, Bluetooth etc. but
cut down everything else running in the background or increasing the boot
duration. Some parts of the stock OS are simulated to make them faster
yet compatible.

The current version is always based on the latest stock OS release.
