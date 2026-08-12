#!/usr/bin/env python3
"""Turn ags-sample's CSV into the average current drawn across each hole in it.

The device cannot be observed while it is off, so every conclusion here is drawn
from what changed across a gap in the log. There are two kinds of gap and they
are told apart by the uptime column, not by the clock:

  suspend       the sampler stopped but the kernel did not, so uptime kept
                counting straight through the gap
  power-cycle   uptime went backwards, so the kernel restarted — the device was
                either genuinely off or sitting in a halt loop

Those two look identical from the outside, and the current is the only thing
that separates them. A real power off draws microamps. A halt loop with the
rails up draws hundreds of milliamps and flattens the battery overnight, which
is the fault this tool exists to confirm or clear.
"""

import argparse
import csv
import sys


def parse_rows(path):
    rows = []
    with open(path, newline="") as fh:
        for record in csv.DictReader(fh):
            try:
                epoch = int(record["epoch"])
                uptime = float(record["uptime"])
            except (KeyError, TypeError, ValueError):
                continue
            counter = (record.get("charge_counter_uah") or "").strip()
            capacity = (record.get("capacity_pct") or "").strip()
            rows.append(
                {
                    "epoch": epoch,
                    "uptime": uptime,
                    "counter": int(counter) if counter.isdigit() else None,
                    "capacity": int(capacity) if capacity.isdigit() else None,
                    "status": (record.get("status") or "").strip(),
                }
            )
    rows.sort(key=lambda r: r["epoch"])
    return rows


def microamps(before, after, seconds, nominal_uah):
    """Average current over the interval, or None when nothing can be said.

    The counter falls as charge leaves the cell. A counter that rose means the
    device was charging, or that the PMIC reset it across a power cycle; either
    way the delta is not a drain and must not be reported as one.
    """
    if before["counter"] is not None and after["counter"] is not None:
        if after["counter"] <= before["counter"]:
            return (before["counter"] - after["counter"]) * 3600.0 / seconds
    if nominal_uah is not None:
        if before["capacity"] is not None and after["capacity"] is not None:
            if after["capacity"] <= before["capacity"]:
                drop = (before["capacity"] - after["capacity"]) / 100.0
                return drop * nominal_uah * 3600.0 / seconds
    return None


def classify(before, after, seconds, gap_threshold):
    if after["uptime"] < before["uptime"]:
        return "power-cycle"
    if seconds > gap_threshold:
        return "suspend"
    return "awake"


def verdict(kind, milliamps):
    """What a current means depends on what the device was claiming to be doing.

    A power-cycle gap is the device claiming to be off, where anything past a
    trickle means it never was. A suspend gap is the device claiming
    suspend-to-RAM, which has its own, much higher, honest floor. Judging both
    against one scale reports a perfectly good suspend as a failed power off,
    which is the exact confusion this tool exists to remove.

    The suspend thresholds are this repository's own prior measurement, not new
    numbers: diagnostics/README.md records that a single-digit-milliamp average
    means real deep sleep and tens of milliamps means fake.
    """
    if kind == "power-cycle":
        if milliamps < 5:
            return "consistent with a real power off"
        if milliamps < 50:
            return "too high for a real power off — something is still powered"
        return "consistent with the SoC still running (halt loop, rails up)"
    if milliamps < 1:
        return "consistent with real suspend-to-RAM"
    if milliamps < 10:
        return "higher than deep sleep should draw"
    return "consistent with fake sleep (suspend-to-idle, CPUs still powered)"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", help="log written by ags-sample")
    parser.add_argument(
        "--interval",
        type=float,
        default=60.0,
        help="the sampler's interval in seconds; anything longer is a gap",
    )
    parser.add_argument(
        "--nominal-uah",
        type=int,
        default=None,
        help="battery capacity in uAh, enabling the capacity-percent fallback "
        "when the coulomb counter is absent or resets across a power cycle",
    )
    args = parser.parse_args(argv)

    rows = parse_rows(args.csv)
    if len(rows) < 2:
        print("fewer than two usable samples; nothing to compare", file=sys.stderr)
        return 1

    gap_threshold = args.interval * 1.5
    findings = []
    for before, after in zip(rows, rows[1:]):
        seconds = after["epoch"] - before["epoch"]
        if seconds <= 0:
            continue
        kind = classify(before, after, seconds, gap_threshold)
        current = microamps(before, after, seconds, args.nominal_uah)
        charging = "Charging" in (before["status"], after["status"])
        if current is None:
            detail = "no usable delta (counter rose, reset, or absent)"
        elif charging:
            detail = "%.1f mA — but the cable was connected, so this is not a drain" % (
                current / 1000.0
            )
        else:
            detail = "%.1f mA" % (current / 1000.0)
        print(
            "%-12s %8.0f s  %3s%% -> %3s%%  %s"
            % (
                kind,
                seconds,
                before["capacity"] if before["capacity"] is not None else "?",
                after["capacity"] if after["capacity"] is not None else "?",
                detail,
            )
        )
        if kind != "awake" and current is not None and not charging:
            findings.append((kind, seconds, current))

    print()
    if not findings:
        print("no suspend or power-cycle gap carried a usable measurement")
        return 0

    print("verdicts")
    for kind, seconds, current in findings:
        print(
            "  %-12s %6.1f h at %7.1f mA — %s"
            % (kind, seconds / 3600.0, current / 1000.0, verdict(kind, current / 1000.0))
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
