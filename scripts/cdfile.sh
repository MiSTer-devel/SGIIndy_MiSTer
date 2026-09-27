#!/usr/bin/env bash
#
# cdfile.sh [--tag T] [--file /dist/NAME] [--fresh PRISTINE.img] [OPT=VAL ...]
#
# Copy one file off the IRIX CD under IRIX, the way an install reads it, and
# say which of its bytes arrived wrong. The reproducer for the CD-install
# corruption of 2026-09-18 (build 44): inst's checksum caught
# /usr/share/data/sounds/prosonus/sfx/alarm_clock.aiff inside
# /dist/dmedia_tools.data with the last 32-bit word of a 512-byte block's high
# halfword replaced by its low one, the same way every time.
#
# The recipe is scripts/cdread.sh's: boot IRIX with the image in the OSD's
# SCSI ID1 slot and the CD in ID6, log in as root, type into the desktop's
# Console window. Here that is
#
#     mount -r -t efs /dev/dsk/dks0d6s7 /CDROM   (harmless if mediad has it)
#     cp /CDROM/dist/NAME /usr/tmp/cdfile.bin; sync
#
# then a halt (init 0), and ON THE BOARD the copy is lifted out of the disk
# image and the original out of the ISO (both with efsread.py) and compared
# byte by byte: every differing byte, with its offset in the file, its offset
# in its 512-byte block, and what the disc holds there.
#
# OPT=VAL are scripts/setopt.sh settings applied before the launch - the A/B
# switches for the hunt: scsicache=on|off (the block cache) and
# lookahead=on|off (the WD33C93B's DATA IN look-ahead). Everything else is
# left at its default.
#
#   bash scripts/cdfile.sh --tag b45 scsicache=on lookahead=on
#   bash scripts/cdfile.sh --tag b45 scsicache=on lookahead=off
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
TAG="cdfile"; FILE="/dist/dmedia_tools.data"; FRESH=""; OPTS=()
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)   TAG="$2"; shift ;;
        --file)  FILE="$2"; shift ;;
        --fresh) FRESH="$2"; shift ;;
        --img)   IMG="$2"; shift ;;
        *=*)     OPTS+=("$1") ;;
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
LOG="tests/out/hw/cdfile-$TAG$(printf -- '-%s' "${OPTS[@]}" | tr '=' '_').log"
stats() { rsh "python3 $DBG/bcnread.py --stats" 2>&1 | tail -1; }
bytes_of() { echo "$1" | sed -n 's/.*data=[0-9.]*s \([0-9.]*\)MB.*/\1/p' | awk '{printf "%d", $1 * 1000000}'; }

rsh "mkdir -p $DBG"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py \
         tools/misterdeploy/bcnread.py tools/misterdeploy/efsread.py; do push "$f"; done

ISO=$(rsh "tr -d '\\0' < /media/fat/config/SGIIndy.s3")
case "$ISO" in *.iso|*.ISO) ;; *) say "no ISO in the ID6 slot (config/SGIIndy.s3 = '$ISO')" | tee -a "$LOG"; exit 1 ;; esac
bash scripts/setopt.sh "${OPTS[@]}" >/dev/null || exit 1
say "options: ${OPTS[*]:-defaults}; image $IMG; CD $ISO; file $FILE" | tee -a "$LOG"
if [ -n "$FRESH" ]; then
    say "restoring $IMG from $FRESH"
    # In place, with the image closed first - see scripts/cdread.sh for why.
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; for i in \$(seq 1 30); do ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q '$IMG\$' || break; sleep 1; done; cp '$FRESH' '$IMG' && sync" || exit 1
fi
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
say "launching $(rsh "md5sum /media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE" | cut -c1-32)" | tee -a "$LOG"
python tools/misterdeploy/launch_unstable_core.py \
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
    --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
    --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1
T0=$(date +%s)
while :; do
    LINE=$(rsh "sleep 20; python3 $DBG/irixstate.py" 2>&1 | tail -1)
    K=$(echo "$LINE" | awk '{print $1}')
    say "$LINE"
    [ "$K" = X-UP ] && break
    [ "$K" = PANIC ] && { say "panicked, giving up" | tee -a "$LOG"; exit 1; }
    [ $(( $(date +%s) - T0 )) -ge 480 ] && { say "no login screen in 480 s" | tee -a "$LOG"; exit 1; }
done
rsh "sleep 15"
say "parking the pointer, logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
rsh "sleep 35"

S0=$(stats); B0=$(bytes_of "$S0")
say "copying $FILE off the CD"
ws "text:mkdir -p /CDROM; mount -r -t efs /dev/dsk/dks0d6s7 /CDROM; rm -f /usr/tmp/cdfile.bin" "sleep:0.3" "kbdRaw:28"
rsh "sleep 8"
ws "text:cp /CDROM$FILE /usr/tmp/cdfile.bin; sync; sync" "sleep:0.3" "kbdRaw:28"
TT=$(date +%s); TFIRST=0; PREV=$B0; STILL=0
while :; do
    S=$(stats); B=$(bytes_of "$S"); NOW=$(date +%s)
    if [ "$B" -gt "$PREV" ] && [ $((B - B0)) -ge 4000000 ]; then
        [ "$TFIRST" = 0 ] && TFIRST=$NOW
        STILL=0
    elif [ "$TFIRST" != 0 ]; then
        STILL=$((STILL + 1))
    fi
    PREV=$B
    [ "$TFIRST" != 0 ] && [ "$STILL" -ge 3 ] && break
    [ "$TFIRST" = 0 ] && [ $((NOW - TT)) -ge 120 ] && { say "no CD traffic in 120 s - the copy did not start" | tee -a "$LOG"; break; }
    [ $((NOW - TT)) -ge 900 ] && break
    rsh "sleep 5"
done
say "after: $(stats)" | tee -a "$LOG"
# The DATA IN capture guard's counters (beacon word 46): how often the capture
# had to wait for the target's buffers, and captures taken while they were not
# ready (only possible with dinstrict=off, or a forced one).
say "$(rsh "python3 $DBG/bcnread.py --stats" 2>&1 | grep '^din:')" | tee -a "$LOG"
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 60"

# The comparison, on the board: both files are lifted into /tmp (RAM) there.
rsh "cd $DBG && python3 efsread.py '$IMG' get /usr/tmp/cdfile.bin /tmp/cdfile.bin >/dev/null && python3 efsread.py '$ISO' get '$FILE' /tmp/cdfile.ref --part 7 >/dev/null" || { say "could not lift the files" | tee -a "$LOG"; exit 1; }
rsh "python3 - /tmp/cdfile.bin /tmp/cdfile.ref; rm -f /tmp/cdfile.bin /tmp/cdfile.ref" <<'PY' | tee -a "$LOG"
import sys
a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
print("copy %d bytes, disc %d bytes" % (len(a), len(b)))
n = min(len(a), len(b))
bad = []
for c in range(0, n, 4096):          # the board's CPU is slow: chunks first
    if a[c:c + 4096] != b[c:c + 4096]:
        bad += [i for i in range(c, min(c + 4096, n)) if a[i] != b[i]]
for i in bad[:40]:
    print("  +0x%07x (block +%3d): got %02x want %02x   copy %s  disc %s"
          % (i, i % 512, a[i], b[i], a[i & ~3:(i & ~3) + 4].hex(), b[i & ~3:(i & ~3) + 4].hex()))
if len(a) != len(b):
    print("CDFILE SHORT")
print("CDFILE %s: %d bytes differ" % ("PASS" if not bad and len(a) == len(b) else "FAIL", len(bad)))
PY
say "done -> $LOG"
