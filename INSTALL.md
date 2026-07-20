## What you need

1. An SD card of 4GB or larger size
2. A disk image flashing tool, e.g. [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

## How to install

1. Download the correct BaseOS image for your device and unzip it. You will get an .img file of about 1 GB size.
2. Use RPI Imager to burn the image to an empty SD card.
   1.  Go to "OS", then scroll down and click User custom.
   2.  Select the .img file you downloaded and click Next.
   3. Select your SD card and write the image
3. Insert the SD card into the 1st SD card slot (usually on the left side) of your RG XX handheld, then power on.

BaseOS will boot up and expand to fill your SD card.

Once it shows "BASE OS" with a check mark, you know it worked.

## How to run NextUI?

You have two options:

A) Install NextUI on the same card

B) Install NextUI on a separate card (recommended).

### Installing NextUI on the same card as BaseOS

1. After the first boot up of BaseOS and you see the check mark, hold the POWER button of your handheld for several seconds to power it off.
2. Take out the SD card and plug it into your computer. You will see a BASEOS volume appear on your computer. This will be your NextUI partition.
3. Install NextUI as usual on this volume (i.e. unzip the contents of the NextUI relase zip file you downloaded). If you want, you can also copy your Roms and Bios now.
4. Eject the SD card and plug it back into your handheld and power it on.

BaseOS will then boot up, install NextUI and launch it.

It takes about 1 to 1.5 min to install, depending on your SD card speed - please be patient!

After the initial install, BaseOS will launch NextUI directly on boot up.

### Installing NextUI on a separate SD card

You don't need to do anything special - just install NextUI as they recommend, on a separate SD card.

Then, insert it into the 2nd SD card slot of your Anbernic handheld.
Keep BaseOS SD card in the 1st SD card slot.

Then, power on your handheld. BaseOS will recognise that SD slot 2 has NextUI and will launch that instead.
