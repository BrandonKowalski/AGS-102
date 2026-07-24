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
- Fast hand-off to a frontend. NextUI is first-class today; the OS remains
  frontend-agnostic.
- First-boot expansion of the data partition to fill the SD card.
- Full support for the handheld's display, sound, controls, networking, HDMI, and
  real suspend-to-RAM.
- SSH active by default.

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
