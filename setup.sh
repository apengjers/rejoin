#!/data/data/com.termux/files/usr/bin/sh
# Rejoin Engine Termux setup script
# Run in Termux: chmod +x setup.sh && ./setup.sh

set -e

echo "Rejoin Engine Termux setup starting..."

if ! command -v pkg >/dev/null 2>&1; then
  echo "Error: 'pkg' not found. Run this script in Termux." >&2
  exit 1
fi

echo "Updating packages..."
pkg update -y || true
pkg upgrade -y || true

echo "Installing required packages: git, lua (or luajit), coreutils, busybox, openssh..."
# Try to install lua; if not available, fall back to luajit
if pkg install -y lua coreutils busybox git openssh >/dev/null 2>&1; then
  echo "Installed lua and required packages"
else
  echo "Package 'lua' not available, trying luajit as fallback"
  pkg install -y luajit coreutils busybox git openssh || true
  # create a lua symlink to luajit if possible
  if command -v luajit >/dev/null 2>&1; then
    PREFIX="$(pkg prefix 2>/dev/null || echo /data/data/com.termux/files/usr)"
    if [ -d "$PREFIX/bin" ]; then
      ln -sf "$(command -v luajit)" "$PREFIX/bin/lua" || true
      echo "Created symlink $PREFIX/bin/lua -> $(command -v luajit)"
    fi
  fi
fi

# lua-posix (OPTIONAL): enables an in-process SIGINT handler. The recommended way to
# stop the monitor is the run.sh wrapper (catches Ctrl+C in the shell and kills the
# Lua process), which works without lua-posix. Only available for Lua PUC-Rio, NOT luajit.
if command -v lua >/dev/null 2>&1 && ! (lua -v 2>&1 | grep -qi "luajit"); then
  echo "Installing lua-posix (optional, improves Ctrl+C)..."
  pkg install -y lua-posix || echo "Warning: lua-posix install failed; use `sh run.sh` for reliable Ctrl+C."
else
  echo "Warning: lua-posix is not available for luajit. Use `sh run.sh` for reliable Ctrl+C."
fi

# Optional: luarocks and cjson
echo "Attempting to install lua-cjson via luarocks (if luarocks installed)..."
if command -v luarocks >/dev/null 2>&1; then
  luarocks install lua-cjson || true
else
  echo "luarocks not found; if you need cjson support, install luarocks and run: luarocks install lua-cjson"
fi

# Create necessary folders
echo "Creating runtime directories..."
mkdir -p "$HOME/rejoin/config"
mkdir -p "$HOME/rejoin/assets"
mkdir -p "$HOME/rejoin/logs"

# If repository wasn't cloned to $HOME/rejoin, user should clone or push files there.
if [ ! -f "$HOME/rejoin/main.lua" ]; then
  echo "Warning: main.lua not found in $HOME/rejoin. Ensure you've copied/cloned the repository to $HOME/rejoin before running." 
fi

# Copy template config if config/config.lua missing
if [ -f "$HOME/rejoin/config/config.lua" ]; then
  echo "config/config.lua already exists — skipping copy."
else
  if [ -f "$HOME/rejoin/config/template.lua" ]; then
    echo "Copying template config to config/config.lua"
    cp "$HOME/rejoin/config/template.lua" "$HOME/rejoin/config/config.lua"
  else
    echo "No config/template.lua found in repository — please ensure files are present." >&2
  fi
fi

# Ensure data log file exists
touch "$HOME/rejoin/data/rejoin.log" || true

echo "Setting file permissions (optional)"
chmod -R u+rw "$HOME/rejoin" || true

cat <<'EOF'

Setup complete.

Next steps (on device):
  cd $HOME/rejoin
  # Run interactive mode (wizard will run if config is new):
  sh run.sh

  # Or run a dry-run monitor simulation (no shell side effects):
  sh run.sh --dry-run --headless --start-monitor

  # Or run headless monitor for real (be careful - will execute am/pidof commands):
  sh run.sh --headless --start-monitor

AutoExecute scripts are managed directly in /sdcard/Delta/Autoexecute from the
"6) AutoExecute Manager" menu (Add/Edit/Delete write straight into that folder).

For Ctrl+C to stop the monitor, run via run.sh (a shell wrapper that catches
Ctrl+C and kills the Lua process). lua-posix is optional: the in-process SIGINT
handler only works when lua-posix is available.

If any commands fail, inspect the log at data/rejoin.log and share it for troubleshooting.

EOF

exit 0
