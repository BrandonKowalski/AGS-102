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

