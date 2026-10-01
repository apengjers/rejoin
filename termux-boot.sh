#!/data/data/com.termux/files/usr/bin/sh
# Rejoin Engine auto-start on device boot (Termux:Boot plugin).
#
# Install (on device):
#   1. pkg install termux-boot          # and install the app from F-Droid
#   2. mkdir -p ~/.termux/boot
#   3. cp termux-boot.sh ~/.termux/boot/start-rejoin.sh
#   4. chmod +x ~/.termux/boot/start-rejoin.sh
#   5. Open the Termux:Boot app once, then restart the phone.
#
# On every boot, Termux:Boot runs every script in ~/.termux/boot/, which opens a
# Termux window and runs this. Equivalent to choosing "1) Launch All + Monitor" from
# the interactive menu: launch all clones (Starting -> Running) with optimizer, then
# keep monitoring until the process is stopped.

REJOIN_DIR=${REJOIN_DIR:-"$HOME/rejoin"}
cd "$REJOIN_DIR" || exit 1
exec lua main.lua --headless --start-monitor --auto-launch
