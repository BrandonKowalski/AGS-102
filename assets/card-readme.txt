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

This card's whole capacity is available now — Base OS expanded it to fill the
card on first boot.
