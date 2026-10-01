#!/data/data/com.termux/files/usr/bin/sh
# Rejoin Engine launcher.
#
# main.lua starts this supervisor automatically. The monitor loop
# spends almost all its time inside os.execute/io.popen (ps, pidof, cookie scan, ...),
# and POSIX blocks SIGINT while inside system()/popen(). This shell wrapper
# catches Ctrl+C itself and kill(1)s the Lua child, which works regardless of what the
# child is doing.
#
# Usage:   lua main.lua [--flags...]
# Ctrl+C in THIS terminal stops the engine; no need to open a second session.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
cd "$SCRIPT_DIR" || exit 1
exec 3<&0
TTY_STATE=
if [ -t 3 ]; then
    stty sane <&3 2>/dev/null
    stty echo icanon opost onlcr <&3 2>/dev/null
    TTY_STATE=$(stty -g <&3 2>/dev/null) || TTY_STATE=
fi
PID=
restore_tty() {
    if [ -n "$TTY_STATE" ]; then
        stty "$TTY_STATE" <&3 2>/dev/null || stty sane <&3 2>/dev/null
    elif [ -t 3 ]; then
        stty sane <&3 2>/dev/null
    fi
    if [ -t 3 ]; then stty echo icanon opost onlcr <&3 2>/dev/null; fi
}
stop_child() {
    if [ -n "$PID" ]; then
        kill -TERM "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null
    fi
    restore_tty
    exit "$1"
}
trap 'stop_child 130' INT
trap 'stop_child 143' TERM
while :; do
    # Explicit stdin redirection prevents POSIX sh from assigning /dev/null to
    # background Lua. fd 3 retains original terminal even without /dev/tty.
    REJOIN_WRAPPER=1 lua main.lua "$@" <&3 &
    PID=$!
    wait "$PID"
    STATUS=$?
    PID=
    restore_tty
    if [ "$STATUS" -ne 75 ]; then exit "$STATUS"; fi
    # Cookie input used a long paste. Redraw a fresh menu in a new Lua process.
    if [ -t 3 ]; then printf '\033[2J\033[H'; fi
done
