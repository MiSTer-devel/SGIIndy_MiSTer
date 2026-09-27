# desktop.sh - sourced, not run: get from IRIX's login chooser to a Console
# that takes typed commands. The caller defines ws() (ws_send.py) and rsh().
#
#   . scripts/desktop.sh
#   login_root      # pointer on the chooser's first icon, `root`, Enter
#   quit_swmgr      # wait for Software Manager, quit it, pointer into the Console
#
# SOFTWARE MANAGER OPENS BY ITSELF ~30 s AFTER A ROOT LOGIN - mediad finds the
# IRIX CD in ID6, mounts it at /CDROM and launches swmgr - on top of the
# Console, and it takes every key typed after that. It ate clockprobe.sh's
# first run, and on 2026-09-27 both cdfile.sh arms (the mount line went into
# its "Available Software" field: "The distribution mkdir -p /CDROM; ... does
# not exist") and audioprobe.sh's playaiff and init 0 - whose "halt reached"
# was swmgr's window pulling index 16 under irixstate.py's X-UP threshold.
# Pointer steps are 1:1 under X (`xset m 0 0` is not needed for these small
# steps; see the desktop input recipe).

login_root() {
    local s=()
    for i in $(seq 1 30); do s+=("mouseMove:-60,-60" "sleep:0.05"); done
    for i in $(seq 1 39); do s+=("mouseMove:7,10" "sleep:0.05"); done
    ws "${s[@]}"
    ws "text:root" "sleep:0.3" "kbdRaw:28"
}

# Let it open and settle, quit it through its File menu, and walk the pointer
# into the Console (clockprobe.sh's sequence: File (68,44), Quit (68,272),
# the Console at (500,600)). Harmless when it never opened: those points are
# desktop background.
quit_swmgr() {
    local s=()
    rsh "sleep 55"
    for i in $(seq 1 40); do s+=("mouseMove:-40,-40" "sleep:0.02"); done
    for i in $(seq 1 17); do s+=("mouseMove:4,0" "sleep:0.02"); done
    for i in $(seq 1 11); do s+=("mouseMove:0,4" "sleep:0.02"); done
    ws "${s[@]}"
    ws "mouseBtn:left" "sleep:1.5"
    s=()
    for i in $(seq 1 57); do s+=("mouseMove:0,4" "sleep:0.02"); done
    ws "${s[@]}"
    ws "mouseBtn:left" "sleep:3"
    s=()
    for i in $(seq 1 108); do s+=("mouseMove:4,0" "sleep:0.02"); done
    for i in $(seq 1 82); do s+=("mouseMove:0,4" "sleep:0.02"); done
    ws "${s[@]}"
    rsh "sleep 3"
}
