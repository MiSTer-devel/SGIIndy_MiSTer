#!/usr/bin/env bash
#
# run-wborder.sh - build and run the dirty-victim ordering image.
#
# A data-cache miss that evicts a dirty line writes the line back and fills
# the new one. However the two are ordered on the way to DDR3, nothing that
# can read the victim may get there before its write: a re-miss on it, an
# uncached read of it, an instruction fill of it, or a prefetch buffer that
# fetched it earlier. tests/wborder/wborder.c checks all four over every set
# of the data cache, and times a stream of dirty misses (its T3 line).
#
#   tests/run-wborder.sh [--no-build]            buffers on
#   tests/run-wborder.sh --no-build --no-dpf     ...extra flags go to the sim

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CROSS="${CROSS:-mipsel-linux-gnu-}"
SIM="${SIM:-$ROOT/verilator/obj_dir/Vsim_top}"
ELF="$ROOT/tests/wborder/build/wborder.elf"

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/tests/wborder" CROSS="$CROSS" >/dev/null || exit 2
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
else
    shift
fi

[[ -x "$SIM" ]] || { echo "no $SIM" >&2; exit 2; }
[[ -f "$ELF" ]] || { echo "no $ELF" >&2; exit 2; }

# --no-gfx: a serial-console image, as tests/run-dma.sh explains.
out="$("$SIM" --elf "$ELF" --testdev --no-gfx --max-cycles 400000000 --stuck 20000000 "$@" 2>&1)"
rc=$?
echo "$out"
echo

fail=0
grep -q "WBORDER: ALL PASS" <<<"$out" || { echo "FAIL: the image reported failures"; fail=1; }
grep -q "FAIL"              <<<"$out" && { echo "FAIL: at least one check failed"; fail=1; }
[[ $rc -eq 0 ]]                       || { echo "FAIL: the image exited rc=$rc"; fail=1; }

[[ $fail -eq 0 ]] && echo "WBORDER: PASS"
exit $fail
