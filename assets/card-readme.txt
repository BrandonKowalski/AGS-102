Base OS — add a frontend to this card
======================================

This card runs Base OS: a minimal Linux that boots your Allwinner H700
handheld and hands off to a frontend. Base OS itself ships no frontend, so
this data partition is empty and ready for you to add one.

To install NextUI (the current first-class frontend):

  1. Copy NextUI's release files onto the root of this card:
        MinUI.zip
        (and any nextui.*.pakz files from the same release)
  2. Optionally add your Roms / Bios / Saves later — the installer creates
     those folders on first run.
  3. Put the card back in the handheld (TF1 slot) and power on.

Base OS detects MinUI.zip, runs NextUI's installer, and launches it. On every
boot after that it goes straight to NextUI in a few seconds.

To run a different frontend, drop its launch payload here instead; the OS
hand-off contract is documented in the Base OS repo (docs/04, docs/01).

Updating Base OS
----------------

You never need to reflash to move to a new Base OS version. Copy the release's
.bosupd file onto this card and power the handheld on. Base OS installs it to
its spare system slot, checks it, switches over and restarts — about a minute.

Your Roms, Bios, Saves and settings are not touched, and the previous version
stays on the card: if the new one cannot start, Base OS returns to it by
itself. You can leave the .bosupd file here; it is only ever applied once.

This card's whole capacity is available now — Base OS expanded it to fill the
card on first boot.

USB cable access
----------------

adb is available automatically over a data-capable USB-C cable.

To make this frontend card appear as a writable USB drive, create BaseOS.conf
in the root of the card with this exact line:

  USB_STORAGE=1

Restart the handheld. Base OS stops the frontend and unmounts the card before
sharing it, so the computer is the only system writing to it. adb remains
available at the same time.

To return to normal, change the line to USB_STORAGE=0 (or remove it), safely
eject the drive on the computer, then restart the handheld. Never restart or
unplug the cable while the computer is writing to the drive.
