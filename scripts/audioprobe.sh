#!/usr/bin/env bash
#
# audioprobe.sh [--tag T] [--fresh PRISTINE.img] [--sound PATH] - the audio
# path under IRIX on the board (docs/design/audio.md).
#
# Boots IRIX with the audio fitted and reads HAL2's beacon words (bcnread.py
# --audio) at each step, which is the evidence nobody has to listen for:
#   1. at the login screen: kdsp_a2 is loaded and its rings are running -
#      PBUS channels 0, 1 and 3 active, codec A frames counting at 48 kHz;
#   2. logged in as root, `playaiff SOUND` typed into the Console: the DAC's
#      peak rises above the silence it had before;
#   3. `init 0`: the machine halts back to the PROM. Before HAL2 had a sample
#      path this is where the desktop froze (the kdsp_a2 bzero spin), so a
#      halt that completes is the old bug's regression check.
# The console's text is not visible from here (it is the frame buffer), so
# the beacon is the whole measurement, sampled every few seconds.
#
#   bash scripts/audioprobe.sh --tag b45 --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
TAG="audio"; FRESH=""; SOUND="/usr/share/data/sounds/prosonus/sfx/alarm_clock.aiff"
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)   TAG="$2"; shift ;;
        --fresh) FRESH="$2"; shift ;;
        --sound) SOUND="$2"; shift ;;
        --img)   IMG="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p tests/out/hw
LOG="tests/out/hw/audioprobe-$TAG.log"
aud() { rsh "python3 $DBG/bcnread.py --audio" 2>&1 | grep '^[0-9:]* audio:' | tail -1; }
peak() { echo "$1" | sed -n 's/.*peak=\([0-9]*\).*/\1/p'; }

rsh "mkdir -p $DBG"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py \
         tools/misterdeploy/bcnread.py; do push "$f"; done
bash scripts/setopt.sh audio=on >/dev/null || exit 1
if [ -n "$FRESH" ]; then
    say "restoring $IMG from $FRESH"
    # In place, with the image closed first - see scripts/cdread.sh for why.
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; for i in \$(seq 1 30); do ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q '$IMG\$' || break; sleep 1; done; cp '$FRESH' '$IMG' && sync" || exit 1
fi
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
say "launching $(rsh "md5sum ${MISTER_RBF_PATH:-/media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE}" | cut -c1-32)" | tee -a "$LOG"
python tools/misterdeploy/launch_unstable_core.py \
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
    --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
    --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1
T0=$(date +%s)
rsh "sleep 25"
say "PROM: $(aud)" | tee -a "$LOG"
while :; do
    LINE=$(rsh "sleep 20; python3 $DBG/irixstate.py" 2>&1 | tail -1)
    K=$(echo "$LINE" | awk '{print $1}')
    say "$LINE"
    [ "$K" = X-UP ] && break
    [ "$K" = PANIC ] && { say "panicked, giving up" | tee -a "$LOG"; exit 1; }
    [ $(( $(date +%s) - T0 )) -ge 480 ] && { say "no login screen in 480 s" | tee -a "$LOG"; exit 1; }
done
A1=$(aud); rsh "sleep 10"; A2=$(aud)
say "login screen: $A1" | tee -a "$LOG"
say "10 s later:   $A2" | tee -a "$LOG"

rsh "sleep 15"
say "logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
rsh "sleep 40"
B=$(aud); say "logged in:    $B" | tee -a "$LOG"
P0=$(peak "$B")
say "playing $SOUND"
ws "text:playaiff $SOUND" "sleep:0.3" "kbdRaw:28"
for i in 1 2 3 4 5 6; do rsh "sleep 3"; say "playing:      $(aud)" | tee -a "$LOG"; done
C=$(aud); P1=$(peak "$C")
if [ -n "$P0" ] && [ -n "$P1" ] && [ "$P1" -gt "$P0" ]; then
    say "AUDIO PEAK ROSE $P0 -> $P1" | tee -a "$LOG"
else
    say "AUDIO PEAK DID NOT RISE ($P0 -> $P1)" | tee -a "$LOG"
fi
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
H=""
for i in $(seq 1 12); do
    rsh "sleep 10"
    S=$(rsh "python3 $DBG/irixstate.py" 2>&1 | tail -1)
    say "$S"
    case "$S" in PROM*|*panel*|*BOOTING*) H="$S"; break ;; esac
done
say "after halt:   $(aud)" | tee -a "$LOG"
[ -n "$H" ] && say "HALT REACHED THE PROM" | tee -a "$LOG" || say "HALT NOT SEEN (check the screen)" | tee -a "$LOG"
say "done -> $LOG"
