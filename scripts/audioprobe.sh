#!/usr/bin/env bash
#
# audioprobe.sh [--tag T] [--fresh PRISTINE.img] [--autoconfig] [--save-as IMG]
#               [--sound PATH] - the audio path under IRIX on the board
#               (docs/design/audio.md).
#
# Boots IRIX with the audio fitted and reads HAL2's beacon words (bcnread.py
# --audio) at each step, which is the evidence nobody has to listen for:
#   1. at the login screen: kdsp_a2 is loaded and its rings are running -
#      words moving through PBUS channels 0, 1 and 3 at 48 kHz;
#   2. logged in as root, `playaiff SOUND` typed into the Console: nonzero
#      samples on the DAC (`last`; `peak` is held since power-on and the
#      PROM's tune has already hit full scale);
#   3. `init 0`: X leaves the screen. Before HAL2 had a sample path the
#      desktop froze here (the kdsp_a2 bzero spin), with X still up.
#
# --autoconfig: THE RELEASE IMAGES' KERNEL HAS NO kdsp_a2. lboot evaluates
# audio.sm's exprobe (HAL2's REV bit 15) when it links the kernel, and every
# kernel on them was linked on a core whose HAL2 read as absent - so build 45's
# first run found nothing in IRIX touching the audio at all. This logs in,
# runs `/etc/autoconfig -f`, `init 6`s onto the relinked kernel and runs steps
# 1-3 there. --save-as keeps that image (e.g. SGIIndy53-audio.img) so later
# runs can start from it with --fresh.
#
# The console's text is not visible from here (it is the frame buffer), so
# the beacon is the whole measurement, sampled every few seconds.
#
#   bash scripts/audioprobe.sh --tag b45 --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img --autoconfig --save-as /media/fat/games/SGIIndy/SGIIndy53-audio.img
#   bash scripts/audioprobe.sh --tag b46 --fresh /media/fat/games/SGIIndy/SGIIndy53-audio.img
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
TAG="audio"; FRESH=""; AUTOCONF=0; SAVEAS=""; SOUND="/usr/share/data/sounds/prosonus/sfx/alarm_clock.aiff"
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)   TAG="$2"; shift ;;
        --fresh) FRESH="$2"; shift ;;
        --sound) SOUND="$2"; shift ;;
        --img)   IMG="$2"; shift ;;
        --autoconfig) AUTOCONF=1 ;;
        --save-as) SAVEAS="$2"; shift ;;
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
words() { echo "$1" | sed -n 's/.* words=\([0-9]*\).*/\1/p'; }
running() { echo "$1" | sed -n 's/.*running=\(0x[0-9a-f]*\).*/\1/p'; }
lastsamp() { echo "$1" | sed -n 's/.* last=\(-\{0,1\}[0-9]*\).*/\1/p'; }
PS_ARG=""       # irixstate.py's panicstr: the release kernel's, until autoconfig relinks it

# X-UP within DEADLINE seconds of T0; with "reboot", only after the screen has
# left X for the PROM and the boot panel first.
wait_x() {
    local deadline=$1 mode=${2:-} left=0
    while :; do
        LINE=$(rsh "sleep 20; python3 $DBG/irixstate.py $PS_ARG" 2>&1 | tail -1)
        K=$(echo "$LINE" | awk '{print $1}')
        say "$LINE"
        [ "$K" != X-UP ] && left=1
        if [ "$K" = X-UP ] && { [ "$mode" != reboot ] || [ "$left" = 1 ]; }; then return 0; fi
        [ "$K" = PANIC ] && { say "panicked, giving up" | tee -a "$LOG"; exit 1; }
        [ $(( $(date +%s) - T0 )) -ge "$deadline" ] && { say "no login screen in $deadline s" | tee -a "$LOG"; exit 1; }
    done
}

# Log in as root and clear Software Manager off the Console: it opens by
# itself after a root login and takes every typed key (scripts/desktop.sh).
. scripts/desktop.sh
login() {
    login_root
    quit_swmgr
}

# Are kdsp_a2's rings running? Words moved over 10 s, and which channels.
rings() {
    local a b
    a=$(aud); rsh "sleep 10"; b=$(aud)
    say "$1: $b" | tee -a "$LOG"
    say "$1: $(( $(words "$b") - $(words "$a") )) words in 10 s, channels $(running "$b")" | tee -a "$LOG"
}

wait_x 480
rings "login screen"

rsh "sleep 15"
say "logging in as root"
login
say "logged in:    $(aud)" | tee -a "$LOG"

if [ "$AUTOCONF" = 1 ]; then
    # The kernel on the release images was configured with HAL2 absent (REV
    # bit 15 set), so lboot left kdsp_a2 out: audio.sm's exprobe reads REV.
    # Relink it now that the probe passes, and boot the new kernel - `init 6`
    # moves /unix.install over /unix on the way down.
    say "autoconfig -f, then init 6 onto the relinked kernel" | tee -a "$LOG"
    ws "text:/etc/autoconfig -f > /usr/tmp/autoconfig.log 2>&1; sync; sync; init 6" "sleep:0.3" "kbdRaw:28"
    rsh "sleep 5"
    bash scripts/grab.sh "${LOG%.log}-autoconfig.png" >/dev/null 2>&1
    T0=$(date +%s)
    PS_ARG="--panicstr 0"     # every symbol moved; judge by the screen alone
    wait_x 1500 reboot
    say "relinked kernel up in $(( $(date +%s) - T0 )) s" | tee -a "$LOG"
    rings "login screen, relinked kernel"
    rsh "sleep 15"
    say "logging in as root"
    login
    say "logged in:    $(aud)" | tee -a "$LOG"
fi

# PLAYBACK. kdsp_a2 starts its rings when something plays, not at boot (build
# 45b: 0 words at the login screen, 496,122 words moved by one playaiff), and
# `peak` is held since power-on - the PROM's tune already hit full scale - so
# the verdict is on `last`: a sampler ON THE BOARD reads the beacon ten times
# a second through the whole sound, started before the command is typed. The
# first version sampled every few seconds from here and missed a 5 s sound.
rsh "rm -f /tmp/aud.txt; (setsid python3 $DBG/bcnread.py --audio --loop 150 --interval 0.1 > /tmp/aud.txt 2>&1 &)"
say "playing $SOUND"
ws "text:playaiff $SOUND" "sleep:0.3" "kbdRaw:28"
rsh "sleep 2"
bash scripts/grab.sh "${LOG%.log}-playing.png" >/dev/null 2>&1
rsh "sleep 12"
rsh "grep ' audio:' /tmp/aud.txt" > "${LOG%.log}-samples.txt" 2>&1
N=$(grep -c ' audio:' "${LOG%.log}-samples.txt")
NZ=$(sed -n 's/.* last=\(-\{0,1\}[0-9]*\).*/\1/p' "${LOG%.log}-samples.txt" | grep -vc '^0$')
W0=$(words "$(head -1 "${LOG%.log}-samples.txt")"); W1=$(words "$(tail -1 "${LOG%.log}-samples.txt")")
RUN=$(grep -c 'running=0x[1-9a-f]' "${LOG%.log}-samples.txt")
say "while playing: $((W1 - W0)) words moved; $N samples, $RUN with a channel running, $NZ with a nonzero sample" | tee -a "$LOG"
if [ "$NZ" -ge 3 ]; then
    say "AUDIO PLAYED" | tee -a "$LOG"
else
    say "AUDIO NOT HEARD ON THE DAC" | tee -a "$LOG"
fi

say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
H=""
for i in $(seq 1 12); do
    rsh "sleep 10"
    S=$(rsh "python3 $DBG/irixstate.py $PS_ARG" 2>&1 | tail -1)
    say "$S"
    # Off X is the kernel alive enough to shut X down; the kdsp_a2 hang of
    # 2026-09 froze the desktop with X on screen.
    [ "$(echo "$S" | awk '{print $1}')" != X-UP ] && { H="$S"; break; }
done
say "after halt:   $(aud)" | tee -a "$LOG"
[ -n "$H" ] && say "HALT: X LEFT THE SCREEN" | tee -a "$LOG" || say "HALT NOT SEEN: X STILL ON SCREEN" | tee -a "$LOG"

if [ -n "$SAVEAS" ]; then
    say "saving the image as $SAVEAS" | tee -a "$LOG"
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; for i in \$(seq 1 30); do ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q '$IMG\$' || break; sleep 1; done; cp '$IMG' '$SAVEAS' && sync && ls -l '$SAVEAS'" | tee -a "$LOG"
fi
say "done -> $LOG"
