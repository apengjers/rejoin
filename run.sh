#!/data/data/com.termux/files/usr/bin/sh
# Rejoin Engine launcher.
#
# Run the engine THROUGH this wrapper so Ctrl+C actually stops it. The monitor loop
# spends almost all its time inside os.execute/io.popen (ps, pidof, cookie scan, ...),
# and POSIX blocks SIGINT while inside system()/popen() -> a raw `lua main.lua` often
# swallows Ctrl+C (the default SIGINT action is unreliable here). This shell wrapper
# catches Ctrl+C itself and kill(1)s the Lua child, which works regardless of what the
# child is doing.
#
# Usage:   sh run.sh [--flags...]
#          (or chmod +x run.sh && ./run.sh ...)
# Ctrl+C in THIS terminal stops the engine; no need to open a second session.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
cd "$SCRIPT_DIR" || exit 1
TTY_STATE=
if [ -t 0 ]; then TTY_STATE=$(stty -g </dev/tty 2>/dev/null) || TTY_STATE=; fi
PID=
restore_tty() {
    if [ -n "$TTY_STATE" ]; then
        stty "$TTY_STATE" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null
    elif [ -t 0 ]; then
        stty sane </dev/tty 2>/dev/null
    fi
    if [ -t 0 ]; then stty echo icanon opost onlcr </dev/tty 2>/dev/null; fi
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
    if [ -t 0 ]; then
        # POSIX shells may give background jobs /dev/null as stdin.
        lua main.lua "$@" </dev/tty &
    else
        lua main.lua "$@" &
    fi
    PID=$!
    wait "$PID"
    STATUS=$?
    PID=
    restore_tty
    if [ "$STATUS" -ne 75 ]; then exit "$STATUS"; fi
    # Cookie input used a long paste. Redraw a fresh menu in a new Lua process.
    if [ -t 0 ]; then printf '\033[2J\033[H' >/dev/tty; fi
done
