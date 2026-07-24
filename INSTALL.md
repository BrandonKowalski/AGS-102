## What you need

1. An SD card of 4GB or larger size
2. A disk image flashing tool, e.g. [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

## How to install

1. [Download](https://github.com/pvaibhav/BaseOS/releases) the correct BaseOS image for your device and unzip it. You will get an .img file of about 1 GB size.
2. Use RPI Imager to burn the image to an empty SD card.
   1.  Go to "OS", then scroll down and click User custom.
   2.  Select the .img file you downloaded and click Next.
   3. Select your SD card and write the image
3. Insert the SD card into the 1st SD card slot (usually on the left side) of your RG XX handheld, then power on.

BaseOS will boot up and expand to fill your SD card.

Once it shows **ADD FRONTEND TO SD CARD**, the expansion is complete.

## How to update BaseOS

You only flash once. Every later version is a file you copy onto the card:

1. [Download](https://github.com/pvaibhav/BaseOS/releases) the `.bosupd` file for your
   device from the new release.
2. Copy it onto the card your handheld reads — the `BASEOS` volume on a one-card
   setup, or your NextUI card on a two-card setup. Anywhere in the root folder.
3. Power the handheld on.

It shows **UPDATING SYSTEM** for about a minute, then restarts into the new version.

Your ROMs, saves, BIOS and settings are not touched. BaseOS installs the update into a
spare system area and only switches over once it has checked it, so a bad download
cannot leave you with a handheld that won't start — and if the new version fails to
start, BaseOS returns to the previous one by itself.

You can leave `.bosupd` files on the card. Each one is only ever applied once, and
anything older than the version you are running is ignored — so old ones lying around
cannot downgrade you or get in the way of a new one. Each release page also lists the
file's SHA-256 checksum if you want to verify your download.

If you copied an update and nothing happened, ask the handheld why over SSH:

```sh
baseos-update status
```

It lists every update file it can see and what it decided about each one.

## How to run NextUI?

You have two options:

### 2-card setup (recommended)

You don't need to do anything special. Just keep BaseOS in the 1st SD card slot as if it's the stock OS.

After you [copy NextUI as they recommend](https://nextui.loveretro.games/getting-started/installation/) on a separate SD card, insert it into the 2nd SD card slot of your Anbernic handheld, and power it up.

BaseOS will recognise that SD slot 2 has NextUI, and begin installing it. It takes about 1 minute, please be patient. Once done, it will launch NextUI. Every subsequent boot will start NextUI as fast as possible.

### 1-card setup: Installing NextUI on the same card as BaseOS

1. After the first boot reaches **ADD FRONTEND TO SD CARD**, power off your device by holding the POWER button.
2. Plug the SD card into your computer. You will see a `BASEOS` volume appear on your computer. This will be your NextUI partition.
3. Install NextUI on this partition [as described here](https://nextui.loveretro.games/getting-started/installation/) (skip the first 3 steps, BaseOS already did that). If you want, you can also copy your Roms and Bios now.
4. Eject the SD card and plug it back into your handheld and power it on.

BaseOS will then boot up, install NextUI and launch it.

