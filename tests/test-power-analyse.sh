#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/diagnostics/power-sampler/ags-analyse.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Four intervals, hand-computed:
#   1->2  60s awake,        dQ 1000uAh    -> 60000uA  =  60.0mA
#   2->3  3600s gap, uptime kept counting -> suspend,  dQ 100uAh   -> 100uA = 0.1mA
#   3->4  60s awake,        dQ 900uAh     -> 54000uA  =  54.0mA
#   4->5  44000s gap, uptime went backwards -> power-cycle,
#         dQ 1800000uAh -> 147272uA = 147.3mA, which is a running SoC, not an off one.
cat > "$TMP/power.csv" <<'CSV'
epoch,uptime,charge_counter_uah,capacity_pct,status
1000,100,2000000,61,Discharging
1060,160,1999000,61,Discharging
4660,3760,1998900,61,Discharging
4720,3820,1998000,60,Discharging
48720,120,198000,6,Discharging
CSV

out="$(python3 "$SCRIPT" "$TMP/power.csv")"
echo "$out"

echo "$out" | grep -q 'suspend' || { echo "no suspend gap classified" >&2; exit 1; }
echo "$out" | grep -q 'power-cycle' || { echo "no power-cycle gap classified" >&2; exit 1; }

# The suspend gap is the microamp case and must read as one.
echo "$out" | grep -E 'suspend.*\b0\.1 mA' >/dev/null \
	|| { echo "suspend gap did not report 0.1 mA" >&2; exit 1; }

# The power-cycle gap is the whole point: 147 mA while supposedly off.
echo "$out" | grep -E 'power-cycle.*\b147\.[0-9] mA' >/dev/null \
	|| { echo "power-cycle gap did not report ~147 mA" >&2; exit 1; }

echo "$out" | grep -q 'SoC still running' \
	|| { echo "no verdict for a 147 mA power-cycle gap" >&2; exit 1; }

# A counter that resets across a power cycle is a real possibility on a PMIC
# nobody has characterised. With --nominal-uah the capacity column carries the
# measurement instead, and without it the tool must say so rather than guess.
# The uptime must go BACKWARDS for this to be a power cycle: 3000 -> 120. The
# counter rises across it, which is what a PMIC that reset its accumulator
# looks like from userspace, and is why the counter path has to decline it.
cat > "$TMP/reset.csv" <<'CSV'
epoch,uptime,charge_counter_uah,capacity_pct,status
1000,3000,2000000,60,Discharging
45000,120,4000000,6,Discharging
CSV

out="$(python3 "$SCRIPT" "$TMP/reset.csv")"
echo "$out" | grep -q 'no usable delta' \
	|| { echo "a risen counter was not reported as unusable" >&2; exit 1; }

out="$(python3 "$SCRIPT" "$TMP/reset.csv" --nominal-uah 3000000)"
# 54% of 3000000uAh = 1620000uAh over 44000s = 132545uA = 132.5mA
echo "$out" | grep -E 'power-cycle.*\b132\.[0-9] mA' >/dev/null \
	|| { echo "capacity fallback did not report ~132.5 mA" >&2; exit 1; }

# Empty charge_counter_uah: board without coulomb counter must yield absent value,
# not zero. With no counter and no fallback, the gap is unmeasurable. With --nominal-uah,
# the capacity column must carry the measurement.
#   5->6  44000s gap, uptime went backwards -> power-cycle,
#         charge_counter_uah empty on all rows; capacity 50% -> 10% = 40% drop
#         40% of 2000000uAh = 800000uAh over 44000s = 65454uA = 65.5mA
cat > "$TMP/empty.csv" <<'CSV'
epoch,uptime,charge_counter_uah,capacity_pct,status
1000,2000,,50,Discharging
45000,100,,10,Discharging
CSV

out="$(python3 "$SCRIPT" "$TMP/empty.csv")"
echo "$out" | grep -q 'no usable delta' \
	|| { echo "empty counter was not reported as unusable without fallback" >&2; exit 1; }

out="$(python3 "$SCRIPT" "$TMP/empty.csv" --nominal-uah 2000000)"
echo "$out" | grep -E 'power-cycle.*\b65\.[0-9] mA' >/dev/null \
	|| { echo "empty counter with capacity fallback did not report ~65.5 mA" >&2; exit 1; }

echo "power analyse tests passed"
