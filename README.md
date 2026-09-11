# Rejoin Engine

Rejoin Engine adalah tools otomatisasi berbasis **Lua** yang berjalan di **Termux/Android** untuk mengelola banyak instance Roblox sekaligus: launching, monitoring, recovery, dan auto rejoin.

- Target: Android 10+, Termux, Lua 5.3 (atau LuaJIT), wajib **root** untuk beberapa aksi.
- Data disimpan lokal. Tanpa server, tanpa backend.

---

## Fitur

- **Multi Instance** — kelola banyak clone Roblox sekaligus, tiap instance punya:
  - `name` (nama instance)
  - `package` (package name clone, contoh `com.apengjers.v3`)
  - `privateServer` (link game / private server)
- **Auto Detect Clone** — Setup Wizard otomatis mendeteksi app/clone Roblox yang terinstall lewat `cmd package resolve-activity`, jadi clone dengan package name di-rename (mis. `com.apengjers.v3`) tetap ketahuan.
- **Launch tiap clone ditarget package** — membuka app clone lewat `am start -a MAIN -c LAUNCHER -p <pkg>` (menarget package eksplisit, jadi tiap clone dibuka sbg task sendiri; tidak butuh `cmd package resolve-activity` yang sering tidak tersedia di Termux non-root). `monkey` & resolve-activity hanya cadangan.
- **Monitor** — loop tunggal, cek tiap instance bergantian. Jika satu instance mati, hanya instance itu yang di-recovery; instance lain tetap diproses.
- **Live status per instance** — monitor menampilkan status tiap instance (`offline`, `starting`, `ingame`, `nologin`, `stuck`, `freeze`, `recovery`) setiap siklus.
- **Auto relaunch freeze** — app yang freeze/stuck lebih dari `freezeTimeout` (default 300 detik / 5 menit) otomatis di-force-stop & di-relaunch.
- **RSS-based health** — clone dideteksi benar-benar jalan (bukan sekadar proses hidup) lewat RSS ≥ `minRss` (default 200 MB). Clone yang di-close (stub RSS rendah) otomatis di-relaunch.
- **Skip restart jika belum login** — clone yang **belum punya akun Roblox login** dan RSS rendah dianggap idle (status `NoLogin`), tidak pernah di-force-relaunch apapun status/kejadiannya (login screen wajar RSS kecil). Deteksi otomatis dengan **scan recursive** token `.ROBLOSECURITY` di direktori data clone (root) — work untuk clone Roblox Lite/mod, bukan cuma `app_webview`. Lihat `Auth` / `cookiePath`.
- **Optimasi RAM/CPU** — semua clone di-deprioritze (`renice 19` + `ionice idle`) supaya 4 floating window tidak rebutan CPU/RAM. Di-apply ulang tiap launch/recovery (karena pid berubah).
- **Recovery** — force-stop → launch → buka game/private server → lanjut monitoring. Dicoba berulang (sesuai `recoveryRetries`).
- **AutoExecute / Script Manager** — kelola **banyak script `.lua`** (global, dipakai semua instance) lewat menu `6) AutoExecute Manager`: List / Create / Edit / Delete / Deploy. Script di-deploy manual ke folder autoexecute tiap aplikasi (`appAutoExecutePath`) via root. Rejoin adalah pengelola script — **semua logika ditulis user** di dalam file script.

---

## Persyaratan

- Android 10+
- Termux + akses root (Magisk/KernelSU) untuk beberapa fitur
- Lua **PUC-Rio** (5.3/5.4) — setup.sh menginstal otomatis untuk `lua`
- Perintah shell Android: `am`, `pm`, `pidof`/`pgrep`/`ps`, `cp`

### Agar Ctrl+C bisa menghentikan program

Monitor nyaris sepanjang waktu berada di dalam `os.execute`/`io.popen` (memanggil `ps`, `pidof`, dsb.), dan POSIX **memblokir SIGINT** saat proses ada di dalam `system()`/`popen()` — jadi `lua main.lua` langsung sering menelan Ctrl+C. Solusinya jalankan lewat **`run.sh`**: shell wrapper itu menangkap Ctrl+C sendiri lalu `kill` child Lua, sehingga berhenti andal dalam satu terminal (tanpa install `lua-posix`, yang tidak tersedia di repo Termux).

```sh
sh run.sh            # atau chmod +x run.sh && ./run.sh ...
```

`lua-posix` (opsional, bila tersedia di device lain) tetap dipakai otomatis oleh `managers/monitor.lua` untuk menghentikan program dari dalam proses.

---

## Quickstart (Termux/Android)

1. Pastikan Termux punya Lua PUC-Rio (`pkg install lua`).

2. Letakkan project di device, lalu jalankan setup (sekali):
   ```sh
   cd ~/rejoin
   chmod +x setup.sh && ./setup.sh
   ```

3. Jalankan tools (pakai `run.sh` supaya Ctrl+C bisa berhenti):
   ```sh
   sh run.sh
   ```
   - Jika `config/config.lua` belum ada, **Setup Wizard** akan berjalan untuk mendeteksi/menambah instance.

4. Gunakan Main Menu untuk: **Instances**, **Settings**, **View Logs**, **Start Monitor**.

### Headless / automated run

- Mulai monitor langsung (tanpa menu):
  ```sh
  sh run.sh --headless --start-monitor
  ```
- Lewati wizard saat config belum ada:
  ```sh
  sh run.sh --no-wizard
  ```
- Simulasi tanpa efek samping shell (dry-run):
  ```sh
  sh run.sh --dry-run --headless --start-monitor
  ```
- Sama seperti Menu 1 (launch semua clone + optimizer, lalu monitor) secara non-interaktif:
  ```sh
  sh run.sh --headless --start-monitor --auto-launch
  ```

### Auto-start saat boot (Termux:Boot)

Biar Termux otomatis terbuka & langsung jalan ke Menu 1 setiap HP dinyalakan:

1. `pkg install termux-boot` + pasang aplikasi **Termux:Boot** dari F-Droid.
2. Siapkan script boot:
   ```sh
   mkdir -p ~/.termux/boot
   cp termux-boot.sh ~/.termux/boot/start-rejoin.sh
   chmod +x ~/.termux/boot/start-rejoin.sh
   ```
3. **Buka aplikasi Termux:Boot sekali** (agar boot receiver terdaftar), lalu reboot HP.
4. Setiap boot, Termux terbuka otomatis dan menjalankan `lua main.lua --headless --start-monitor --auto-launch` (setara pilih menu `1`).

### Matikan auto-boot

Gemana cara mematikannya? Tarik script dari folder boot agar Termux:Boot tidak menjalankannya lagi saat HP dinyalakan:

```sh
rm ~/.termux/boot/start-rejoin.sh
```

Setelah dihapus, Termux tidak akan otomatis membuka & menjalankan engine lagi di boot berikutnya. (Fungsi Manual via `sh run.sh` tetap jalan seperti biasa; boot yang sudah berjalan tetap bisa dihentikan manual.)

---

## Konsep: Package Name Clone

Tiap instance diidentifikasi lewat **package name**, bukan path folder.

Jika kamu pakai **app cloner** untuk menggandakan Roblox, setiap clone punya package name unik, contoh:

- `com.apengjers.v3`
- `com.apengjers.v4`
- `com.apengjers.v5`

Masukkan masing-masing package name ke `package` pada konfigurasi instance. Setup Wizard mode **Auto Detect** bisa menemukannya otomatis; mode **Manual** tersedia untuk instance yang tidak terdeteksi.

---

## Konfigurasi

File: `config/config.lua` (dibuat dari `config/template.lua` saat pertama kali).

Contoh:

```lua
return {
    -- AutoExecute kini Script Manager GLOBAL: script disimpan di autoExecuteDeployPath,
    -- di-deploy manual via menu "Script Manager" ke tiap aplikasi (appAutoExecutePath).
    monitorInterval = 5,       -- detik antar siklus monitor
    recoveryDelay = 3,         -- jeda antar percobaan recovery
    recoveryRetries = 3,       -- berapa kali recovery dicoba
    checkTimeout = 15,         -- detik menunggu app jadi sehat
    debug = true,
    autoExecuteDeployPath = "data/autoexecute",
    logPath = "data/rejoin.log",

    -- Wajib diisi untuk Deploy (Script Manager): folder autoexecute di aplikasi.
    -- Butuh root. Contoh: "/data/data/com.roblox.client/files/autoexecute"
    appAutoExecutePath = "",

    -- Filter cepat opsional untuk Auto Detect (mis. "com.apengjers."). Kosong = nonaktif.
    clonePackagePrefix = "",

    -- Deteksi freeze/stuck.
    freezeTimeout = 300,        -- detik app boleh freeze sebelum di-relaunch (5 menit)
    gracePeriod = 30,           -- detik setelah launch sebelum dinilai ingame vs stuck
    anrCheckEnabled = true,     -- deteksi ANR via logcat (best-effort, lebih andal dgn root)
    minRss = 200,               -- MB ambang proses clone dianggap AKTIF (RSS)

    -- Deprioritze semua clone siram RAM/CPU.
    optimizer = {
        enabled = true,
        renice = 19,   -- prioritas CPU (makin besar makin rendah; 19 = terkecil)
        ionice = 3,    -- kelas I/O (3 = idle)
    },

    instances = {
        {
            id = 1,
            name = "Main",
            package = "com.apengjers.v3",
            privateServer = "https://www.roblox.com/games/107778070777162/Steal-An-Egg",
            -- cookiePath (opsional): base direktori data clone utk deteksi login (scan
            -- recursive token .ROBLOSECURITY). Kosong = pakai default /data/data/<package>
            -- Kosong = pakai default /data/data/<package>/app_webview/Default/Cookies
        },
        {
            id = 2,
            name = "Clone1",
            package = "com.apengjers.v4",
            privateServer = "https://www.roblox.com/share?code=62e6ddb1dc13094d872ea3f91ec427c8&type=Server"
        }
    }
}
```

### Format `privateServer`

Field `privateServer` (atau link game) menerima beberapa format:

| Jenis | Contoh |
| --- | --- |
| Public game link | `https://www.roblox.com/games/107778070777162/Steal-An-Egg` |
| Private server share link | `https://www.roblox.com/share?code=62e6ddb1dc13094d872ea3f91ec427c8&type=Server` |
| Roblox deep link | `roblox://experiences/107778070777162` |

Catatan link:
- Link dikirim ke `am start VIEW` setelah dinormalisasi dengan aman, dan **ditarget ke package clone** (`-p <pkg>`) agar deep link `roblox://` masuk ke clone yang benar, bukan handler default bersama.
- Link **private server `/share` selalu dibuka apa adanya** (tidak diubah).
- Link **game publik otomatis dikonversi ke deep link** `roblox://experiences/<placeId>` agar Roblox langsung join place (URL https hanya membangunkan app tanpa masuk game).
- Link yang tidak valid / berisi karakter berbahaya akan ditolak.

---

## Struktur Project

```
rejoin/
├── main.lua                    # entry point + main menu
├── setup.sh                    # setup skrip Termux
├── termux-boot.sh              # template auto-start saat boot (Termux:Boot)
├── debug_probe.lua             # alat diagnostik manual: cek isRunning/isActive per clone
├── launch.log                  # auto-debug tiap siklus menu 1 (Launch + Monitor)
├── config/
│   ├── config.lua              # konfigurasi aktif (dibuat otomatis dr template)
│   ├── template.lua            # template konfigurasi
│   └── sample_AutoExecute.lua  # contoh script AutoExecute
├── core/
│   ├── config.lua              # loader & saver config
│   ├── logger.lua              # logger ke file
│   ├── state.lua               # state machine sederhana
│   ├── setup.lua               # pastikan config ada
│   ├── setup_wizard.lua        # wizard setup (auto-detect + manual)
│   ├── instances_cli.lua       # menu instances
│   ├── autoexecute_cli.lua     # menu AutoExecute / Script Manager
│   ├── settings_cli.lua        # menu settings
│   ├── logs_cli.lua            # viewer log
│   └── runtime.lua             # flag runtime (dry-run)
├── managers/
│   ├── apk.lua                 # launch, force-stop, isRunning, isActive, getRSSinKB
│   ├── instance.lua            # manager instance
│   ├── monitor.lua             # loop monitor
│   ├── recovery.lua            # engine recovery
│   ├── optimizer.lua           # renice/ionice deprioritasi clone
│   ├── autoexecute.lua         # Script Manager (list/save/remove/deploy global)
│   └── auth.lua                # deteksi login via cookie (.ROBLOSECURITY)
├── utils/
│   ├── shell.lua               # eksekusi shell (dengan timeout anti-hang)
│   ├── probe_log.lua           # auto-debug per siklus -> launch.log
│   ├── android.lua             # wrapper am/intent
│   ├── file.lua, json.lua, timer.lua
└── data/
    ├── rejoin.log              # log runtime
    └── autoexecute/            # folder deploy AutoExecute
```

---

## Menu

### Main Menu
- `1) Launch All + Monitor` (launch semua instance + join game, langsung masuk monitor dengan status live)
- `2) Instances Manager`
- `3) Settings`
- `4) View Logs`
- `5) Start Monitor`
- `6) AutoExecute Manager`
- `7) Exit`

### Instances Manager
- List, Add, Edit, Delete instance

### AutoExecute / Script Manager (menu `6`)
- `1) List`, `2) Create`, `3) Edit (overwrite)`, `4) Delete`, `5) Deploy`, `6) Exit`
- Create/Edit: ketik kode baris-per-baris, akhiri dengan baris **`END`** di paling bawah (baris `END` tidak disimpan). Setelah create ditanya "Mau tambah lagi? (y/n)".
- Deploy menyalin tiap script ke `appAutoExecutePath/<name>.lua` di tiap instance (via root). Wajib isi `appAutoExecutePath` di config.

### Settings
- `monitorInterval`, `recoveryDelay`, `recoveryRetries`, `checkTimeout`
- `debug` (toggle)
- `appAutoExecutePath`, `autoExecuteDeployPath`, `logPath`
- `clonePackagePrefix`
- `freezeTimeout` (detik sebelum relaunch app freeze), `gracePeriod`, `anrCheckEnabled`

---

## Logging

- File log: `data/rejoin.log` (path bisa diubah di Settings → `logPath`).
- Mencatat aktivitas: launch, recovery, join, error, sukses.
- Lihat via menu `View Logs`, atau langsung di device.

---

## Lisensi / Kontribusi

Project ini dikembangkan mandiri untuk keperluan otomatisasi. Gunakan dengan bijak sesuai ketentuan platform Roblox dan kebijakan masing-masing perangkat.
