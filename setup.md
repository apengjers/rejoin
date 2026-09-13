## 📝 Installation Guide

## 🛠️ Step 1: Enable Freeform Windows
1. **Enable Developer Options:** Settings > About Phone > Tap Build Number 7 times.
2. **Enable Flags:** Go to System > Developer Options > Under Apps, enable:
   - ✅ Enable freeform windows
   - ✅ Force activities to be resizable
   - ✅ Enable non-resizable in multi-window
3. **Reboot your device.**

## ⚡ Step 2: Configure Root & Termux
1. Enable **Magisk** (or **KernelSU**) and **LSPosed** or **Root Permission** (RF).
2. Open **Magisk/Kitsune/Root Permission** > **Superuser** > Ensure **Termux** is granted root access.
*Note:  If you cannot find the Termux app in Magisk/Kitsune or KernelSU, skip this step and proceed to the next step.*

## 📦 Step 3: Termux Setup
Run this single command in Termux ([Download Termux](https://f-droid.org/packages/com.termux/)):
💻 Desktop Copy:
```bash
termux-setup-storage && pkg update -y && pkg upgrade -y && pkg install -y lua53 tsu python figlet android-tools sqlite && pip install pyfiglet rich
```
📱 Mobile Copy:
`termux-setup-storage && pkg update -y && pkg upgrade -y && pkg install -y lua53 tsu python figlet android-tools sqlite && pip install pyfiglet rich`
*Grant storage permission when prompted and type “y” if asked.*

## 📥 Step 4: Install Script **(Latest Version)**
**Android 10:**
💻 Desktop Copy:
```bash
curl -L -o /sdcard/download/kaeru.lua https://raw.githubusercontent.com/pgen0x/kaeru/refs/heads/main/kaeru.lua
```
📱 Mobile Copy:
`curl -L -o /sdcard/download/kaeru.lua https://raw.githubusercontent.com/pgen0x/kaeru/refs/heads/main/kaeru.lua`

**Android 12+:**
💻 Desktop Copy:
```bash
curl -L -o /sdcard/Download/kaeru.lua https://raw.githubusercontent.com/pgen0x/kaeru/refs/heads/main/kaeru.lua
```
📱 Mobile Copy:
`curl -L -o /sdcard/Download/kaeru.lua https://raw.githubusercontent.com/pgen0x/kaeru/refs/heads/main/kaeru.lua`

## 🚀 Step 5: Run & Setup
1. Execute
**Android 10:**
💻 Desktop Copy:
```bash
lua /sdcard/download/kaeru.lua
```
📱 Mobile Copy:
`lua /sdcard/download/kaeru.lua`

**Android 12+:**
💻 Desktop Copy:
```bash
lua /sdcard/Download/kaeru.lua
```
📱 Mobile Copy:
`lua /sdcard/Download/kaeru.lua`

2. Setup
**License Key:** Enter your key when prompted (get key <#1441082362766036992>).
**Select Packages:** Press **Enter** to auto-detect Roblox. (*If it is not detected, type manual. To find the Roblox package name:* <#1442135281569628241> )
**Final Settings:** Configure delay and Private Server URL.
——————
**To reset the config settings, you can use this command.**
**Android 10:**
💻 Desktop Copy:
```bash
lua /sdcard/download/kaeru.lua --reset
```
📱 Mobile Copy:
`lua /sdcard/download/kaeru.lua --reset`

**Android 12+:**
💻 Desktop Copy:
```bash
lua /sdcard/Download/kaeru.lua --reset
```
📱 Mobile Copy:
`lua /sdcard/Download/kaeru.lua --reset`

*Note: Grant Root permissions when prompted.*