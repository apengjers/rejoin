# Heartbeat Monitoring (HTTP)

Sistem "detak jantung" biar Rejoin tahu bahwa **game di dalam clone benar-benar masih
jalan** — bukan cuma prosesnya hidup.

- Clone mengirim sinyal HTTP tiap 10 detik ke server kecil di Termux.
- Rejoin membaca sinyal itu tiap siklus monitor:
  - sinyal segar (≤ `heartbeat.timeout`, default 30 dtk) → status **Running**.
  - sinyal pernah ada tapi kadaluarsa → status **Freeze** → setelah `freezeTimeout`
    (default 5 menit) clone di-relaunch otomatis.
- Tanpa signal sama sekali (belum pernah ada) → Rejoin **fallback ke logika RSS/proc**
  yang biasa, jadi tidak ada perilaku berubah sampai fitur diaktifkan.

## Mengapa HTTP, bukan file / bukan HttpService

| Metode | Status |
|---|---|
| `HttpService:PostAsync("http://127.0.0.1:...")` | ❌ **Tidak bisa.** HttpService di-proxy lewat server Roblox; `127.0.0.1` di sana bukan device lo. |
| `writefile` / file bersama | ✅ bisa, tapi kamu pilih HTTP |
| **`request()` / `http_request()` raw executor** | ✅ **Ini yang dipakai.** Socket benar-benar keluar dari device → ke server Termux di loopback. |

Syarat: **executor Delta lo punya fungsi `request`/`http_request`** (kebanyakan executor
modern punya, model Synapse). Kalau tidak ada, fitur ini tidak bisa jalan.

## Cara kerja

```
[Roblox clone (Delta)]                                  [Termux]
scripts/heartbeat.lua (AutoExecute, tiap launch)        sh run.sh -> Start Monitor
  while task.wait(10) --- request POST
    http://127.0.0.1:8080/heartbeat
        { app = "<key>", acc = "<username>" }  ──────►  scripts/heartbeat_server.py
                                                          (stdlib Python, auto-start/stop)
                                                        data/heartbeat_state.txt  ← ditulis tiap sinyal
                                                          ▲
Rejoin monitor tiap siklus ── baca state file ──────────┘
  key = instance.heartbeatKey  ATAU  username akun (resolve dari cookie)
  umur ≤30s -> Running | umur >30s -> Freeze -> 5 menit -> relaunch
```

**Matching identitas:** key sinyal = username akun clone (uniqu, di-resolve otomatis
dari cookie `.ROBLOSECURITY` → API). Jadi kalau sinyal `apengjers3` berhenti, yang
di-freeze & di-relaunch adalah clone ber-paket `com.apengjers.v3` — presisi, tidak
mungkin kenak clone lain. (Alternatif deterministik: isi `heartbeatKey` per instance
dan pakai key yang sama di script.)

## Aktifkan

1. **Atur config** — `config/config.lua`:
   ```lua
   heartbeat = {
       enabled = true,        -- ← aktifkan
       host = "127.0.0.1",
       port = 8080,
       timeout = 30,          -- detik tanpa sinyal sebelum dianggap freeze
       statePath = "data/heartbeat_state.txt",
   },
   ```
   Optionally `heartbeatKey = "apengjers3"` di tiap instance.

2. **Pasang script in-game** via AutoExecute Manager:
   ```sh
   sh run.sh  →  6) AutoExecute Manager  →  1) Add
   ```
   Tambahkan isi `scripts/heartbeat.lua` (yang ada di repo ini). Delta menjalankan
   script di folder AutoExecute setiap launch, jadi heartbeat menyala sendiri.

3. **Jalan**: `sh run.sh` → `1) Launch All + Monitor` atau `5) Start Monitor`.
   - Rejoin otomatis menyalakan server Python di `127.0.0.1:8080` (log di
     `data/heartbeat_server.log`) dan mematikannya saat monitor berhenti.

## Verifikasi cepat

1. Health server: dari Termux jalankan
   ```sh
   curl -s http://127.0.0.1:8080/health
   ```
   → harus balasan `{"<key>":<epoch>}` setelah clone mengirim sinyal.

2. State file: `cat data/heartbeat_state.txt` → baris `key=epoch` tiap clone.

3. Jika tidak ada data: cek `data/heartbeat_server.log` (server), lalu pastikan
   script in-game benar-benar jalan (nama file di Delta AutoExecute) dan akun sudah
   ter-resolve (lihat `data/username_scan.log`).

## Perilaku status

Semantik dipakai **selalu**, terlepas `heartbeat.enabled` on/off:

| Kondisi | Status di dashboard |
|---|---|
| Proses hidup (RSS aktif) TANPA sinyal / heartbeat off | `Ingame` (hijau) — game jalan, eksekusi belum dikonfirmasi |
| Sinyal segar ≤30s (eksekusi terkonfirmasi) | `Running` (hijau) |
| Sinyal kadaluarsa (>30s) & akun login | `Freeze` (kuning) → relaunch 5 menit |
| Sinyal berhenti & akun tidak login | `NoLogin` (dim, tidak pernah relaunch) |
| Belum pernah ada sinyal | `Ingame` (kondisi pertama) |

**Kolom `HB`** di tiap baris = bukti visual apakah server Termux benar-benar menerima
sinyal dari clone tsb, cocok 1-1 per package:

- `12s` hijau — sinyal terakhir baru
- `1m30s` kuning — sinyal lama (jalan menuju Freeze)
- `-` — belum pernah ada sinyal untuk clone ini (script belum jalan / belum pernah terima)
- `OFF` — fitur heartbeat dimatikan di config

Di bawah tabel ada baris status server: `HB server: ON :8080 (pid 1234) | N key terhubung` —
kalau belum `ON`, cek log `data/heartbeat_server.log`. Kalau `-` semua padahal `ON`,
berarti script in-game belum ter-eksekusi (Delta key / nama file).

> **Deteksi no-login kini lebih ketat**: validasi token asli (`WARNING:-DO-NOT-SHARE!…`)
> ditambah cross-check API Roblox (`/users/authenticated`). Kalau deteksi gagal total
> (root/grep error), clone **dianggap belum login** → tidak pernah di-relaunch, dengan
> peringatan di log. Hanya ketika API tidak terjangkau (offline) determinasi tetap
> dianggap login supaya clone beku tetap bisa ke-relaunch.

> **Catatan penting:** kalau script di dalam game berhenti (bug/kick) tapi game-nya
> sendiri normal, clone **tetap** di-*freeze* & di-*relaunch* (sesuai permintaan: 30s
> tanpa sinyal = freeze). Itu memang semantik heartbeat.

## Troubleshooting

- **`data/heartbeat_server.log` tidak ada / server gagal start** → cek apakah `python`
  terinstall (`pkg install python`), dan folder `data/` ada di `~/rejoin`.
- **State file kosong meski game jalan** → script in-game belum ke-eksekusi (cek nama
  file di Delta AutoExecute) atau `request()` tidak tersedia di executor (lihat log).
- **Key tidak match** → isi `heartbeatKey` di config instance dengan string yang sama
  yang dipakai script, atau pastikan username ter-resolve (lihat `username_scan.log`).
- **Port 8080 bentrok** → ganti `heartbeat.port` di config (server di-restart oleh
  Rejoin saat monitor start).
- **Floating window** — pastikan scripting Delta **tetap jalan** saat window di-minimize;
  kalau di-pause, heartbeat stop → false-freeze. (Klaim Delta aman, tapi cek setelah
  sample berjalan.)