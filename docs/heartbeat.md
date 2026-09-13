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
       strict = true,         -- server-first (lihat "Mode strict" di bawah)
       noSignalGrace = 180,   -- detik proses hidup tanpa sinyal sebelum di-Freeze
   },
   ```
   Optionally `heartbeatKey = "apengjers3"` di tiap instance, dan/atau
   `heartbeatRequired = true/false` untuk override `strict` per clone.

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

### Mode strict (server-first)

Saat `heartbeat.strict = true` **dan** server `ON`, Rejoin tidak percaya RSS untuk
klaim "hijau". Sebuah clone yang **diperolehkan** kirim sinyal (bakal ter-resolve +
akun login + proses hidup) tapi tidak pernah mengirim sama sekali selama
`noSignalGrace` detik → di-*Freeze* & dipulihkan/relaunch (sinyal memang wajib untuk
clone itu). Prioritas kondisi:

| Clone ... | dengan strict | hasil |
|---|---|---|
| baru dapat sinyal fresh | — | `Running` |
| sinyal stale & login | — | `Freeze` → relaunch 5 mnt |
| proses hidup ≥ `noSignalGrace` TANPA sinyal + key ter-resolve + login | `true` | `Freeze` → relaunch 5 mnt |
| belum pernah sinyal TAPI key masih nil / account logout / proses mati / server OFF | apa pun | tetap RSS safety: `Ingame`/`Offline`/`NoLogin` — **tidak di-Freeze** |

Override per clone: `heartbeatRequired = false` → clone itu tak pernah di-Freeze karena
diam (mis. sementara Delta/key belum beres); `heartbeatRequired = true` memaksanya.

**Safety anti relaunch-spam**: freeze-relaunch selalu di-gate status login — clone tanpa
akun login tidak pernah di-relaunch paksa.

**Kolom `HB`** di tiap baris = bukti visual apakah server Termux benar-benar menerima
sinyal dari clone tsb, cocok 1-1 per package:

- `12s` hijau — sinyal terakhir baru
- `1m30s` kuning — sinyal lama (jalan menuju Freeze)
- `-` — belum pernah ada sinyal untuk clone ini (server menerima sinyal lain, tapi bukan dari clone ini)
- `?` **merah** — heartbeat ON tapi **key clone ini belum ter-resolve** (username gagal resolve dari cookie). Jangan dianggap "OFF": fitur aktif, hanya identitas clone yang tidak ketahui. Diagnostik: `lua tools/username_diag.lua`.
- `OFF` — fitur heartbeat dimatikan di config

Di bawah tabel ada baris status server: `HB server: ON :8080 (pid 1234) | N key terhubung` —
kalau belum `ON`, cek log `data/heartbeat_server.log`. Kalau `-` semua padahal `ON`,
berarti script in-game belum ter-eksekusi (Delta key / nama file). Kalau ada baris merah
`N clone username belum ter-resolve`, jalankan diagnostik:

```sh
lua tools/username_diag.lua
```

Script itu mencetak, per package: apakah data-dir ada, apakah token `.ROBLOSECURITY`
ketemu (panjang + bagian depan disensor), hasil mentah API `/users/authenticated`, dan
hasil scan lokal — jadi titik gagal username langsung kelihatan (jangan berharap status
benar kalau key-nya masih `?`). Semua path baca&log sudah absolut, jadi hasil konsisten
walau `main.lua` dijalankan dari folder mana pun.

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