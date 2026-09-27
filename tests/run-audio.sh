#!/usr/bin/env bash
# run-audio.sh - the audio path end to end, from the PROM's own code.
#
# Boots the real IP24 PROM with the audio fitted (--audio): the PROM finds
# HAL2 (REV bit 15 clear), decodes its startup tune from ADPCM into RAM,
# builds an EOX descriptor chain, and plays it through PBUS DMA channels 1 and
# 2 into HAL2 at 44.1 kHz. The harness records the DAC (--wav), and
# tools/prom_tune.py decodes the same tune straight from the PROM image and
# checks the recording plays it sample for sample, scaled by the volume the
# PROM sets (its NVRAM default, "volume=80"). Then hinv must list the audio
# processor, which is the line IRIX's audio.sm probe and the PROM agree on.
#
# The simulator's audio clock is a tenth of the core clock (sim_top.sv), like
# its microsecond, so the tune's 2.09 s is ~10M cycles and the PROM's own
# wait for it (0xBFC03578) still covers it.
#
#   tests/run-audio.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${SIM:-$ROOT/verilator/obj_dir/Vsim_top}"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
OUT="$ROOT/tests/out/audio-console.txt"
WAV="$ROOT/tests/out/audio-prom.wav"

EXPECT=(
    "Running power-on diagnostics"
    "System Maintenance Menu"
    "Command Monitor."
    # hinv's audio line: REV 0x4010 printed as 4.1.0 beside the PROM's "A2".
    "Audio: Iris Audio Processor: version A2 revision 4.1.0"
)

FORBID=(
    "Diagnostics failed"
    "Exception"
)

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]]  || { echo "no $SIM" >&2; exit 2; }
[[ -f "$PROM" ]] || { echo "no PROM at $PROM" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

echo "booting $(basename "$PROM") with the audio fitted ..."
"$SIM" --prom "$PROM" --no-gfx --wav "$WAV" \
       --max-cycles 600000000 --stuck 150000000 \
       --type-on 'Option?' '5\r' \
       --type-on 'Command Monitor' 'hinv\r' \
       --stop-on 'revision 4.1.0' \
       --console "$OUT" > "$ROOT/tests/out/audio-sim.txt" 2>&1

fail=0
for e in "${EXPECT[@]}"; do
    if grep -qF -- "$e" "$OUT"; then
        printf '  ok      %s\n' "$e"
    else
        printf '  MISSING %s\n' "$e"; fail=1
    fi
done
for f in "${FORBID[@]}"; do
    if grep -qF -- "$f" "$OUT"; then
        printf '  REGRESSED, must not appear: %s\n' "$f"; fail=1
    fi
done
grep -E '^audio:|^wav:' "$ROOT/tests/out/audio-sim.txt" | sed 's/^/  /'

# The tune itself, against the PROM image. Volume 80 is the PROM's NVRAM
# default (the "volume" variable at 0xBFC6E808), written to both of HAL2's
# volume registers before it plays.
tune=$(python3 "$ROOT/tools/prom_tune.py" "$PROM" check 0 "$WAV" 80 2>&1)
echo "$tune" | sed 's/^/  /'
grep -q 'TUNE CHECK PASS' <<< "$tune" || fail=1

echo
echo "console output is in ${OUT#"$ROOT"/}, the DAC in ${WAV#"$ROOT"/}"
[[ $fail -eq 0 ]] && echo "AUDIO: PASS" || echo "AUDIO: FAIL"
exit $fail
