# Changelog

## Unreleased / Bug fixes

- **Inject Cookie (multi-DB, fix "ga kelogin padahal [OK]")**: sebelumnya inject SELALU menulis ke `app_webview/Default/Cookies` (`locateCookieDb` ambil `head -n 1`), padahal clone mod/Lite bisa menyimpan profile WebView live di direktori lain (`app_webview/<profile>/Cookies`) — injeksi masuk ke DB yang **tidak pernah dibaca app**, sehingga token VALID + row utuh (verifikasi ketat lolos) tapi UI tetap logout. Sekarang `locateCookieDbs` (plural): `find -maxdepth 6 -name Cookies` mengumpulkan **SEMUA** Cookies DB, dan inject menulis row yang sama ke **tiap DB** (backup `<db>.bak-<ts>` per DB → DELETE ragged rows → INSERT schema dinamis → `wal_checkpoint(TRUNCATE)` → verifikasi ketat `len==#token` & count==1 per DB). Gagal satu DB di-lapor dengan path-nya; sukses sebagian → `[WARN]`. Dump (menu 8) kini men-dump **semua** DB ber-label path.
- **Inject Cookie (auto diagnostik pasca-launch)**: setelah launch + `[CEK]`, CLI otomatis mencetak `probeToken`: per-DB status baris `.ROBLOSECURITY` (`len|count`) + hasil `grep -a -r -l -F` prefix token di seluruh base dir → memperlihatkan **file lain** yang menyimpan token (tanda mod menyimpan session di luar WebView). Menghilangkan tebak-tebakan: kalau token hanya ada di Cookies DB → live store murni WebView; kalau muncul file lain → lokasi session mod yang sebenarnya.

- **Inject Cookie (rule pakai 1 clone = 1 akun)**: root cause "inject berhasil tapi ga kelogin" terakhir = **session di-revoke server-side karena satu token dipakai login ke banyak clone/device beruntun** (Roblox force-logout SEMUA sesi, termasuk browser sumber). Bukti log: token VALID (HTTP 200) sebelum inject (`00:45:43`) dan 4 detik setelah app dibuka (`00:45:49`), value utuh 1200 char (verifikasi ketat lolos) — jadi serialize inject/DB tidak bersalah; session mati *setelah* app authenticate. Kini opsi 1 mencetak **banner peringatan** sebelum paste: 1 token = 1 clone = 1 akun; token yang dipakai >1 clone → force-logout + rotasi. Rekomendasi hasil: untuk tiap clone, export + inject token akun yang BEDA, lalu verifikasi visual (avatar/username muncul = login sukses).

- **Inject Cookie (login fix)**: verifikasi pasca-INSERT kini **ketat** — `length(value)` harus **persis sama dengan panjang token asal** (sebelumnya cukup `>0`, sehingga value yang terpotong/rusak di-shell masih lolos `[OK]` tetapi cookie invalid → app tetap di layar login). Mismatch → `[GAGAL] INJECT TERPOTONG/RUSAK` dengan angka char tersimpan vs asal + lokasi backup.
- **Inject Cookie (auto-launch + re-check)**: setelah inject `[OK]`, CLI otomatis **membuka clone** (`APK.launch`) supaya app langsung authenticate ke Roblox (mempersempit jendela revoke session server-side dan menghapus langkah manual "buka app"), lalu **verifikasi ulang token via curl 4 detik setelah launch** dan mencetak `[CEK]` apakah session masih VALID atau sudah di-REVOKE. Ini memisahkan dua kelas kegagalan: (a) token di-revoke server (bukan bug inject), (b) session masih valid tapi app tetap di layar login → masalah DB/WebView yang nyata untuk diburu lebih jauh.

- **Inject Cookie (terminal I/O)**: alur token kini **tanpa input sama sekali setelah paste**. Opsi 1 (Inject) & 3 (Cek validitas) membaca token (`readToken()` yang langsung menghapus baris echo paste 1170-char dari layar), lalu **`os.exit(0)`** begitu hasil tercetak — tidak ada lagi `io.read()` pasca-paste, tidak ada submenu/menu yang menunggu input yang tidak datang. Terminal jadi mandek karena *paste raksasa diikuti blok baca*; dengan membunuh proses segera setelah inject, tidak pernah ada momen "nunggu input beku". Konfirmasi inject cukup `type 'y'`. Setelah selesai kembali ke shell (`~ $`), tinggal `lua main.lua` bila mau menu lain. Opsi 2 (Dump, tanpa paste) tetap one-shot balik ke menu utama. Pengaman ekstra `core/logger.lua`: echo log ke konsol di-cap 200 char + `...` (file log tetap penuh) — melindungi baris raksasa jika `logLevel=DEBUG` di-flick. Risiko sisa hanya jika UI Termux beku *di tengah* paste: swipe-close session → buka baru (ketik/Enter/Ctrl+C bisa ikut mati di level OS, di luar jangkauan script).

- **Inject Cookie (UX anti-stuck)**: submenu now one-shot — habis aksi (inject/dump/cek token) muncul `[Selesai] Tekan Enter untuk kembali ke menu utama`, `io.read()` sekali menelan sisa buffer stdin hasil paste token besar (yang bisa mendesync keyboard Termux), lalu otomatis `break` balik ke Menu Utama. Tidak ada lagi kondisi "macet di submenu / input ga respon" pasca-inject. Pemulihan darurat tetap: `Ctrl+C` → `lua main.lua`.

- **Inject Cookie**: menu `7) Inject Cookie` (`core/inject_cookie_cli.lua` + `managers/cookie_injector.lua`) — inject token `.ROBLOSECURITY` ke Cookies DB WebView clone pilihan dari config. Auto `am force-stop` dulu, target path memakai `Auth.getBaseDir()` (hormati override `cookiePath`), deteksi DB via app_webview/Default/Cookies + fallback `find -maxdepth 5 -name Cookies`, butuh `sqlite3` (`pkg install sqlite`). Runner sqlite di-resolve otomatis: `su` tidak mewarisi PATH Termux, jadi dicoba `env PATH=<termux>/bin:/system/bin LD_LIBRARY_PATH=<termux>/lib <termux>/bin/sqlite3`, lalu path absolut Termux, lalu `sqlite3` sistem; tiap kandidat diuji `SELECT 1;`. Schema dibaca dinamis (`pragma_table_info`, 6 kolom) sebelum `INSERT OR REPLACE`, row mengikuti **jejak nyata login in-app** (di-verifikasi dari dump clone yang berhasil login): `host_key='.roblox.com'` (dengan titik, domain cookie), `expires_utc=14380828598000000` (WebKit µs ~2056), `samesite=-1` (UNSPECIFIED), `source_scheme=2` (HttpsOrigin), `source_port=443`, `top_frame_site_key=''` (legacy/unpartitioned agar match semua top frame), kolom ekstra NOT NULL tanpa default diisi literal kosong sesuai tipe. Sebelum INSERT: **verifikasi remote token** via curl → `users.roblox.com/v1/users/authenticated` — **fail-closed**: hanya respons `HTTP 200` + body berisi `"name"` yang lolos; semua kondisi lain dibatalkan dengan pesan yang menampilkan respos server (~160 char). Verifikasi memakai **satu panggilan curl di stdout** (`-w '\n%{http_code}'`) — tidak ada lagi file temp `$$.json` (sebelumnya `$$` beda PID antar `su -c` → body selalu kosong). B2: fix `tonumber(string.gsub(...))` yang mem-boom nge-crash (`base out of range`) karena gsub mengembalikan 2 nilai; verify remote dibungkus pcall. Fitur baru: submenu `3) Cek validitas token` di Inject Cookie (geser Exit ke 4) untuk cek token tanpa inject. DELETE semua baris `.ROBLOSECURITY` usang (host_key salah/top_frame penuh) supaya cuma satu baris bersih, `creation_utc`/`last_access_utc` diisi WebKit-µs sekarang (mirror login asli), verifikasi akhir `length|count` harus `1170|1`. Backup DB ke `<db>.bak-<ts>`, `PRAGMA wal_checkpoint(TRUNCATE)`, `Auth.resetCache()`. `core.main` expose `Auth.getBaseDir()`. Debug: menu `8) Dump Cookies (debug)` (`core/dump_cookies_cli.lua` + `CookieInjector.dump()`) menampilkan semua baris cookies (value hanya panjangnya) buat diff login kerja vs hasil inject. Main menu: Exit digeser ke `9)`.

- Auto clear cache saat launch: `cacheCleaner` (default ON) — cache tiap clone dibersihkan setiap cold start / relaunch (setelah force-stop, sebelum launch) via `rm -rf` manual terhadap dir cache app (sama dengan tombol Settings "Clear cache"; **`pm clear-cache` tidak ada di Android**): `cache/`, `code_cache/`, external cache, dan dengan `clearWebView=true` + WebView caches (`app_webview/Default/{Cache,Service Worker,Code Cache,GPUCache}`). Log mengukur byte `before/after` sebagai bukti. CLI manual: `lua main.lua --clear-cache`. Login aman: Cookies (`.ROBLOSECURITY`), Local Storage, `shared_prefs`, databases, `files` tidak pernah disentuh. Module baru `managers/cache_cleaner.lua`, call site di-wrap pcall di `recovery.lua` (launchAndJoin/relaunch/checkAndRecover).

## v0.1

Initial Project

- Project Structure
- Logger
- State Manager

---

## Unreleased / Bug fixes

- Launch APK: resolve real launchable activity (`cmd package resolve-activity`) with `monkey` fallback instead of hardcoded `.MainActivity`
- Process detection: `pidof` -> `pgrep` -> `ps` fallback chain for `isRunning`
- Monitor/recovery: correct success/failure handling around pcall + recovery boolean
- AutoExecute: treat global `config.autoExecute` as the shared script; per-instance path is an optional override
- Config template/working config: removed per-instance `autoExecutePath` in favour of the global AutoExecute path

---

## v0.2 — Android clone integration

- Auto-detect Roblox apps/clones during Setup Wizard via `cmd package resolve-activity` (works for renamed clones like `com.apengjers.v3`), plus optional `clonePackagePrefix` fast filter. Manual input still available.
- New `utils/roblox_link.lua`: safe game-link normalization
  - Public game links (`https://www.roblox.com/games/<placeId>`) optionally converted to `roblox://experiences/<placeId>`
  - Private server share links (`https://www.roblox.com/share?code=...&type=Server`) always opened as-is
  - Unknown/invalid links rejected safely
- Recovery now opens the instance game/private-server link through the normalizer before `am start VIEW`
- New settings: `clonePackagePrefix`, `normalizeGameLink`
- Main Menu: new shortcut `Launch + Join an instance` (choose an instance, launch its app and open its game link manually via `Recovery.launchAndJoin`)

---

## v0.3 — Launch-all + live per-instance status

- Main Menu `1) Launch + Join` now launches ALL configured instances (no manual pick), then immediately starts the monitor.
- New `managers/status.lua`: tracks per-instance status — `offline`, `starting`, `ingame`, `stuck`, `freeze`, `recovery`.
- Freeze detection via logcat ANR (`ANR in <package>`) with a grace-period fallback for `stuck`.
- `Recovery.relaunch()` force-stops and relaunches an app that has stayed frozen for `freezeTimeout` (default 300s, counted from when stuck/freeze was set).
- Monitor prints a live per-instance status table each cycle.
- New settings: `freezeTimeout`, `gracePeriod`, `anrCheckEnabled`.

---

## v0.3.1 — Fix launch & public link

- Launch now uses `monkey -p <pkg> -c LAUNCHER 1` FIRST (works in Termux without `cmd package resolve-activity`, which is unavailable in a non-root Termux shell); resolve-activity is only a fallback and no longer blocks the launch. Fixes instances not opening.
- Public game links are now ALWAYS converted to the deep link `roblox://experiences/<placeId>` so Roblox joins the place directly (an https URL only wakes the app without entering the game).
- Removed the `normalizeGameLink` setting/config/menu option (public links always deep-link; private `/share` links are still opened as-is).
- `utils/android.lua` launch updated to match the monkey-first strategy.

---

## v0.3.2 — Fix multiple-clone launch (App Cloner floating)

- Launch now targets the package EXPLICITLY first: `am start -a MAIN -c LAUNCHER -p <pkg>`. This starts each clone's own launcher task (works for App Cloner clones like `com.apengjers.v3`/`v4`, whose activities stay `com.roblox.client.*`) without depending on `cmd package resolve-activity`. `monkey` and resolve-activity remain fallbacks.
- "Launch All" (`main.lua` option 1) now pauses ~3s between instances so a floating-window clone appears before the next one is launched.
- `Android.openURL` now accepts an optional target package and opens the game link with `-p <pkg>` so a `roblox://experiences/<placeId>` deep link is delivered to the correct clone instead of a single shared default handler. Falls back to a non-targeted VIEW if the targeted start fails.

---

## v0.3.3 — Fix disappearing config & stuck "ingame" status

- `core/config.lua serializeTable`: array/numeric keys now serialize as real integer keys (`[1] = ...`) instead of string keys (`["1"] = ...`). Previously a save rewrote `instances` with string keys which `ipairs` could not read, so a later save blanked the config to `instances = {}`.
- `managers/instance.lua load` + `core/setup_wizard.lua nextId`: read with `pairs()` and normalize mixed string/number keys so configured instances always survive a reload.
- `managers/apk.lua isRunning`: process matching is now anchored to the START of the process command (`^<pkg>($|:)`) instead of a loose substring. This fixes status getting stuck at "ingame" after an app is closed (a leftover process containing the name as a substring no longer counts), so the monitor now reports `offline` and recovers/relaunches the app.

---

## v0.3.4 — Launch one clone at a time

- `Recovery.waitUntilRunning()` added: after launching a clone, poll `APK.isRunning()` until its process is observed (then a short settle pause) or a timeout elapses.
- "Launch All" (menu 1) now launches clones ONE AT A TIME — it waits for each clone to reopen before starting the next, so multiple floating-window clones each get a chance to appear instead of one being crowded out (previously a fixed 3s pause / then a monitor that still reported "starting").
- New settings (Settings menu → `14) Edit launch wait settings`): `launchWaitInterval` (3s), `launchWaitTimeout` (90s), `launchSettleDelay` (5s).

---

## v0.3.5 — Fix launch hang (isRunning never matched)

- Fixed `managers/apk.lua escapeRegex`: the replacement was producing `%.` (percent-dot) instead of `\.` (backslash-dot), so the `pgrep -f '^com\.apengjers\.v6($|:)'` pattern never matched and `isRunning` always returned false. `waitUntilRunning` then waited a full timeout per clone, making "Launch All" appear stuck (repeating `pidof`/`pgrep`/`ps`).
- `escapeRegex` now emits backslash escapes (`\.`) valid for POSIX ERE (`pgrep -f`).
- `ps -A` fallback compares the process command start with a plain (non-regex) check (`cmd == pkg or cmd starts with pkg..":"`) instead of feeding an ERE pattern to Lua's `string.match`.

---

## v0.3.6 — Count-based launch wait + public link joins the map

- New `managers/apk.lua APKManager.countProcess(name)`: counts running processes for a base name (e.g. `com.roblox.client`) via pgrep/pidof/ps. App Cloner clones all run as `com.roblox.client`, so the count tracks how many clones are actually up regardless of the renamed package.
- `Recovery.waitUntilRunning` now accepts a `target` count: it waits until `countProcess(processCheckName) >= target` (then a settle pause) or a (shortened) timeout. Default `launchWaitTimeout` lowered 90→30s so a failed detection never hangs "Launch All".
- "Launch All" (`main.lua`) records a baseline `countProcess` before the loop, then after launching clone `i` waits for `count >= baseline + i` before starting the next — launching one clone at a time, each confirmed open before the next.
- New setting `processCheckName` (default `com.roblox.client`) — the base process counted; editable via Settings → `14) Edit launch wait settings`.
- `utils/roblox_link.lua`: public game links now convert to `roblox://placeId=<placeId>` (deep link that drops straight into the game/map) instead of `roblox://experiences/<placeId>` (which only opened the game's page on mobile).

---

## v0.3.7 — Root (su) process detection + direct-join deep link

- **Root required** (`utils/shell.lua`): every shell command now runs through `su -c '...'` when `useRoot` is enabled (default `true`). This is the real fix for "detection looks broken": on a rooted device Android 11+, Termux running as a NORMAL user cannot see other apps' processes, so every `pidof`/`pgrep`/`ps` probe returned empty and every instance looked offline. Running as root (Magisk) makes the Monitor see the real per-clone processes again. Set `useRoot = false` on a non-root device.
- **Correct process model**: App Cloner clones keep their OWN package process name (`com.apengjers.v3`, etc. — verified from the clone APK manifest and on-device `su -c "pidof com.apengjers.v3"`), NOT `com.roblox.client` as v0.3.6 assumed. `com.roblox.client` is only the class/activity base, not the process name.
- `managers/apk.lua`: new `APK.countRunning(packages)` counts how many of the given configured packages report `isRunning` — accurate per-clone count without needing a shared base name.
- `Recovery.waitUntilRunning` + "Launch All": replaced the `countProcess(processCheckName)` target with `targetCount` of running instances (`countRunning >= baseline + i`). Drops the now-unneeded `processCheckName` setting.
- `utils/roblox_link.lua`: public game links now convert to **`robloxmobile://placeID=<placeId>`** (capital `ID`) — the scheme the clones register and that `ActivityProtocolLaunch` handles by joining the map directly — instead of `roblox://placeId=<placeId>` which only opened the game's page. `robloxmobile://` added to the accepted-scheme whitelist.
- New setting `useRoot` (default `true`), editable via Settings → `14) Edit launch wait settings`.

---

## v0.3.8 — Quiet monitor + direct-join deep link

- `core/logger.lua`: new console `logLevel` filter (default `INFO`). `Logger.debug` lines are now hidden unless `logLevel = "DEBUG"`, fixing the monitor being flooded with `su -c ...` and per-probe `pidof`/`pgrep`/`ps` debug spam every cycle. Set to DEBUG via Settings → `15) Edit logLevel` for troubleshooting.
- `managers/status.lua printSummary`: status table rewritten as one compact line — e.g. `1=starting  2=running  3=freeze  4=recovery` — instead of the verbose multi-line log-style output.
- New setting `logLevel` (default `INFO`), editable via Settings → `15) Edit logLevel`.
- `utils/roblox_link.lua`: public game links now convert to **`roblox://experiences/start?placeId=<placeId>`** — the deep link form Roblox uses to START/join the game directly. Earlier formats (`roblox://experiences/<id>`, `roblox://placeId=...`, `robloxmobile://placeID=`) only opened the game's page on this client. Example: `https://www.roblox.com/games/110776611234/Steal-An-Egg` → `roblox://experiences/start?placeId=110776611234`.

---

## v0.3.9 — Force ActivityProtocolLaunch for direct join

- `utils/android.lua openURL`: public-game links are now delivered by forcing the clone's **`ActivityProtocolLaunch`** handler via `am start -a VIEW -d '<url>' -n <pkg>/com.roblox.client.ActivityProtocolLaunch`, instead of the old `-p <pkg>` (which lets Android pick an activity that only shows the game's page). Falls back to `-p <pkg>` then an untargeted VIEW, logging which strategy ran.
- `utils/roblox_link.lua`: public links convert back to **`robloxmobile://placeID=<placeId>`** — the form that `ActivityProtocolLaunch` on the App Cloner clones joins straight into the map (verified on the cloned Roblox activity set and the Android direct-join path).

## v0.4.0 — roblox://placeId= auto-join via -p (proven per-clone)

- `utils/roblox_link.lua`: public game links convert to **`roblox://placeId=<placeId>`** (was `robloxmobile://placeID=` / earlier `roblox://experiences/start?placeId=`).
- `utils/android.lua openURL`: primary strategy is now **`am start -a VIEW -d '<url>' -p <clone>`**; the `-n <pkg>/com.roblox.client.ActivityProtocolLaunch` strategy (which only opened the game page) is removed. Untargeted VIEW remains as fallback.
- On-device testing proved `roblox://placeId=<id>` delivers the clone's deep-link join directly into the map, and `-p com.apengjers.v3/v4` routes each to its own account.

## v0.4.1 — wait for clone before joining

- `managers/recovery.lua launchAndJoin`: now polls until the clone's process is running (up to `checkTimeout`, with a short `launchSettleDelay` settle) **before** sending the deep link. Previously the join link was sent immediately after launch, landing while the app was still on the splash screen, so Roblox showed the game's page instead of auto-joining. Mirrors the wait already done by the monitor's `recover` path.

## v0.4.2 — direct deep-link join + Ctrl+C hard stop

- `managers/recovery.lua launchAndJoin`: instances with a `privateServer` are now joined by sending the deep link **directly** (`openGameLink`), **without** a separate `APK.launch` (MAIN/LAUNCHER) first. On-device proof: firing `roblox://placeId=<id>` + `-p <clone>` at a cold clone auto-joins the map, whereas launching through the launcher activity first left the app on its home screen so the link only showed the game page. `APK.launch` is still used for instances with no link.
- `main.lua`: Ctrl+C hard stop — `prompt()` now `os.exit(0)` when `io.read()` returns nil (Ctrl+C/EOF in the menu), plus "tekan Ctrl+C untuk berhenti" hints in the menu and before the monitor starts.

## v0.4.3 — cold start (force-stop) before join

- `managers/recovery.lua launchAndJoin`: instances with a `privateServer` are now **force-stopped first** (`APK.forceStop(pkg)`, 1s settle) before the join deep link `roblox://placeId=<id>` + `-p <clone>` is sent. On-device proof: option-A join only auto-enters the map from a *cold* clone; if the clone is still warm the link just shows the game page. This makes the tool mirror the manual procedure that worked (force-stop → join link).
- Instances without a link still use `APK.launch(pkg)`.

## v0.4.4 — self-contained join link in recovery.lua

- `managers/recovery.lua`: `openGameLink` is now **self-contained** — it extracts the place id and builds `roblox://placeId=<id>` directly (no longer depends on `utils/roblox_link` syncing to the device). Handles `https://www.roblox.com/games/<id>/...`, `?placeId=<id>`, `roblox://placeId=<id>`, `roblox://experiences/<id>`. Private-server `/share` links stay untouched. Removed the unused `RobloxLink` require. This guarantees the tool sends the proven auto-join form regardless of other files.
- Prior fix (v0.4.3) already force-stops the clone (cold start) before sending the link.

## v0.4.5 — colored live-status dashboard + Ctrl+C actually stops monitoring

- `managers/status.lua`: `printSummary` now clears the terminal (`\27[2J\27[H`) each cycle and renders a full multi-row, colorized table instead of stacking plain lines:
  - left column = package clone (`com.apengjers.v3`), right column = status label + color (Running=green, Stuck=red, Recovery=yellow, Starting=cyan, Offline=dim).
  - footer rows show real **Memory Usage** (`/proc/meminfo`: % + free MB) and **Storage Available** (`df -h`), best-effort with a 30s cache to avoid shell cost every cycle.
- `managers/monitor.lua`: installs a **SIGINT handler via lua-posix** so Ctrl+C truly stops monitoring on Termux. Root cause fixed: `os.execute("sleep")` swallows SIGINT (POSIX `system()` blocks it), so without a handler Ctrl+C did nothing; the handler flips `running = false`.
- `utils/timer.lua`: new `Timer.sleepInterruptible(seconds, isStopped)` sleeps in 0.25s steps, so once the SIGINT handler fires the monitor exits within ~0.25s instead of waiting out the whole interval. Monitor loop now uses it.
- `main.lua`: after the monitor stops, if `Monitor.interrupted()` is true (Ctrl+C pressed) the program exits cleanly (`os.exit(0)`) instead of returning to the menu.
- **Requires** `pkg install lua-posix` on Termux for Ctrl+C to work.
- Cleanup: removed now-unused `utils/roblox_link.lua`, `debug_normalize.lua`, and `debugging.txt`; updated `README.md` and `docs/roadmap.md` references.

## v0.4.6 — fix misaligned monitor table

- `managers/status.lua`: fixed the status-table layout that rendered with borders "straying" into the middle of rows on Termux:
  - **Border width now equals body width** (they were out by 4 chars, so the `+`/`|` separators never lined up). The border is generated from the same width as a data row.
  - The frame is built as **one single string** and cleared+written in a single `io.write("\27[2J\27[H" .. frame)` + flush, instead of clearing in a separate `io.write` — the earlier cursor-home (`\27[H`) wrote into the middle of later printed rows.
  - `\27[0m` reset is only emitted on colored status cells (no stray escapes on the header/footer rows).
  - Column widths tuned (Instance 24 / Status 18) so values like `com.apengjers.v3`, `38% (2466MB Free)`, and `75G Free` fit without overflow.

## v0.4.7 — flicker-free in-place dashboard + clean console

- `managers/status.lua`: `printSummary` now redraws **in place** instead of full-screen clearing every cycle:
  - Tracks the drawn frame height and moves the cursor back up (`\27[<n>A`) each refresh, then redraws and clears any leftover below (`\27[J`) — no more screen flicker.
  - Rows are joined with **`\r\n` (CRLF)** instead of `\n` — fixes rows drifting rightward on Termux (LF alone doesn't reset the column to 0 when ONLCR is off), which was the root cause of the "stray border" mess visible both on screen and in copy/paste.
  - Hides/shows the cursor around each draw (`\27[?25l`/`\27[?25h`) for a smooth refresh.
  - New `Status.resetDashboard()` resets the frame position at the start of each monitor session.
- `core/logger.lua`: added `Logger.setConsoleVisible(bool)`. When `false`, log lines are written to the file only (not the console), so monitor event logs don't push the dashboard around.
- `managers/monitor.lua`: hides console logging while monitoring (`Logger.setConsoleVisible(false)` + `Status.resetDashboard()`), and restores it plus the cursor (`\27[?25h\r\n`) when the monitor stops.
- Net effect: monitoring shows only a clean, non-flickering status dashboard; full logs still go to `data/rejoin.log`; Ctrl+C stops and returns to a normal console.

## v0.4.8 — box-drawing dashboard + silent launch + "Resetting" status

- `managers/status.lua`:
  - Dashboard now uses **Unicode box-drawing** borders (`╭─┬─╮`, `├─┼─┤`, `╰─┴─╯`, `│`) instead of ASCII `+ - |`, matching `examplecli.txt`.
  - Status cells render as **`Label (Color)`** (e.g. `Resetting (Yellow)`, `Running (Green)`), with the label colored by status.
  - `Starting` now renders **blue** (was cyan); added a **color legend** under the table (Resetting/Recovery = Yellow, Stuck = Red, Starting = Blue, Running = Green) plus the Ctrl+C footer hint.
- New internal status **`resetting`** (`STATUS_UI["resetting"] = Resetting, yellow`): `Status.beginResetting(id)` / `Status.endResetting(id)` mark an instance while it is being force-stopped / relaunched / joined, and `Status.check` holds it (like `recovery`) so the dashboard shows "Resetting (Yellow)" until the operation finishes.
- `managers/recovery.lua`:
  - `launchAndJoin` and `relaunch` now set/unset the `resetting` status around their work.
  - Launch progress logs (`launchAndJoin`, `relaunch`, `waitUntilRunning`) downgraded from `Logger.info` to `Logger.debug` (kept in the log file, not shown on the console).
- `main.lua`:
  - Removed the startup debug prints (`monitorInterval`, `instance count`).
  - Option `1) Launch All + Monitor` now hides console logging for the whole launch phase (`Logger.setConsoleVisible(false)`), strips all per-clone progress text, and goes **straight to the dashboard** once the (still sequential, still waiting) launch finishes.

## v0.4.9 — clean start + exact process detection (closed app now reopens)

- `managers/monitor.lua`:
  - `Monitor.start` now **clears the screen** (`\27[2J\27[H`) right before the dashboard so leftover menu text doesn't sit above it — picking `1)` goes straight to a clean full-screen dashboard.
  - Instance health is now based on the **real process state every cycle** (`apkManager.isRunning`), no longer inherited from a stale status memory (`ingame/starting/freeze`). This ensures a closed app is detected and recovered instead of staying "healthy" forever.
- `managers/apk.lua` — `isRunning`:
  - Root cause of "app closed but not reopening": the process match included sub-processes (`com.apengjers.v3:p0`) that keep running as background services after the UI is swiped away, so `isRunning` stayed `true` → status stuck at `ingame` → recovery was never triggered.
  - Now matches the clone's **exact main process name only** (`com.apengjers.v3`, no trailing `:`), so once the UI is closed (main process gone) the instance is seen as not-running and the monitor reopens/re-covers it.
- `managers/status.lua`:
  - Status cells no longer append the color name (`Resetting (Yellow)` → **`Resetting`**), still colorized by status.
  - Removed the legend block (`* ... = ...`) — the Ctrl+C footer hint is kept.

## v0.5.0 — RSS-based health (force-close detected & reopened)

- Root cause: force-closing a floating-window clone leaves a low-RSS stub process alive (~7 MB vs ~235 MB for a running clone), so process-based detection (`isRunning`) reported it as running forever and never recovered it.
- Confirmed on-device that `dumpsys activity`/`dumpsys window` do NOT list the App Cloner floating-window clones at all (even when fully running), so UI-visibility cannot be used as a health signal here.
- `managers/apk.lua`: new `APK.getRSSinKB(pkg)` (parses resident memory from `ps -A`) and `APK.isActive(pkg)` = process exists AND RSS >= `config.minRss` (default 50 MB).
- New setting `minRss` (MB) in `config/config.lua` and `config/template.lua` — a running clone is `isActive`, a force-close stub is not.
- `managers/monitor.lua`: health (does the clone need recovery) uses `isActive` instead of `isRunning`.
- `managers/recovery.lua`: post-launch success check uses `isActive`, so recovery only completes once the clone has genuinely loaded (real memory).
- `managers/status.lua`: dashboard "running/ingame/offline" classification uses `isActive` so a force-closed clone shows `offline` instead of a stale `ingame`.
- New diagnostic tool `debug_probe.lua` (run `lua debug_probe.lua`) printing per-clone `pidof`/`ps` RSS/state plus the `isActive` decision vs the RSS threshold.
- `utils/shell.lua`: every shell command now runs under `timeout` (default 10s, configurable via `shellTimeout`) so a hung `su`/`dumpsys` call can no longer freeze the tool and stop Termux accepting input.
- `debug_probe.lua`: removed all `dumpsys` calls — on this device they never list the clones and the heavy calls hung the terminal.
- Automatic diagnostics on Menu 1 (Launch + Monitor): new `utils/probe_log.lua` writes one line per clone per monitor cycle to `launch.log` (time, status, running, isActive, pid, RSS, RSS threshold) plus recovery/relaunch event lines. No manual debug tool needed — after reproducing a bug, just read `launch.log`. New settings: `launchLogPath` (default `launch.log`), `launchLogEnabled`.

## v0.6.0 — RAM/CPU optimization

- **RSS threshold tuned for real device**: observed running clones at ~1 GB and a force-close stub at ~188 MB, so `minRss` default raised 50 → **300 MB** (kept clean separation below real running, above the stub).
- New `managers/optimizer.lua`: deprioritizes every Roblox clone with `renice 19` (lowest CPU priority) + `ionice -c 3` (idle I/O) so four floating windows stop fighting for CPU/RAM. JSON config `optimizer` (`enabled`, `renice`, `ionice`).
- Optimizer is re-applied after every launch AND every recovery/relaunch — each clone restart gets a new pid, so tuning must be re-run each time.
- Fix: `Shell.exec` returns `(ok, output)`; any `pcall(function() return Shell.exec(...) end)` previously captured the boolean as the "output string" (crashes with `attempt to index a boolean value`) and would have crashed `optimizer.lua`/`probe_log.lua` during Menu 1. All sites now capture the 3rd pcall value (`local ok, _, out = pcall(...)`).
- Removed the experimental auto-resize (2×2 grid / `windowLayout` / `debug_resize.lua` / `display.md`) — results were poor, reverted to keep only the optimizer.
- `main.lua`: new `--auto-launch` flag — `lua main.lua --headless --start-monitor --auto-launch` behaves exactly like Menu 1 (launch all clones + optimizer, then monitor) without a terminal prompt.
- New `termux-boot.sh` template + README section: auto-open Termux and run Menu 1 on every device boot via the Termux:Boot plugin (`~/termux/boot/start-rejoin.sh`).

## v0.7.0 — AutoExecute Script Manager + no-restart-if-not-logged-in

- **AutoExecute is now a Script Manager (not per-package injection)**:
  - `managers/autoexecute.lua` rebuilt: `dir` / `list` / `save` / `read` / `remove` / `deployOne` / `deployAll`. Scripts are stored GLOBALLY under `autoExecuteDeployPath` (default `data/autoexecute`) and copied as-is (root, `su`) into each application's `appAutoExecutePath/<name>.lua`. Removed the old single-file `inject`/`deployScriptForInstance` model.
  - New `core/autoexecute_cli.lua`: Script Manager submenu (List / Create / Edit / Delete / Deploy / Exit). Code is typed line-by-line and ends with a bare `END` line (which is NOT saved); after a create it asks "Mau tambah lagi? (y/n)" and loops. Deploy requires `config.appAutoExecutePath` (set it — the app's autoexecute folder; root needed to write app data).
  - `main.lua`: new menu option `6) AutoExecute Manager` (Exit moved to `7)`).
  - `config/template.lua` + `core/settings_cli.lua`: removed the obsolete global `config.autoExecute`; added/edited `appAutoExecutePath` setting.
  - `managers/recovery.lua`: removed the old `AutoExecute.inject` call during recovery.
  - `utils/file.lua`: new `File.listDir(path, ext)` used to list global scripts.

- **Do not restart a clone that has no logged-in account**:
  - New `managers/auth.lua`: `Auth.isLoggedIn(instance)` reads the clone's WebView cookie DB (default `/data/data/<pkg>/app_webview/Default/Cookies`, override per-instance via `cookiePath`) and looks for a `.ROBLOSECURITY` token (via root `grep -a`). Returns `true`/`false`/`nil`.
  - `managers/status.lua`: when a clone is low-RSS AND not logged-in (`isLoggedIn == false`) it is marked **`nologin`** instead of `freeze` — the freeze/relaunch clock never starts for it.
  - `managers/monitor.lua`: a `nologin` clone is not recovered/relaunched (low RSS is expected on the login screen). On a failed detection (`nil`) behavior falls back to the normal freeze/relaunch so nothing regresses.
  - Dashboard shows the new `NoLogin` (dim) status.

- **Tuned values**: `freezeTimeout` 60 → **300 s** (uniform for all freeze cases) in `config/config.lua`, `config/template.lua`, and the `managers/status.lua` default; `minRss` 300 → **200 MB** in `config/template.lua` (running `~1 GB` vs stub `~188 MB`).

## v0.7.1 — Ctrl+C actually stops the program

- **Root cause**: `Timer.sleep` fell back to `os.execute("sleep ...")`. POSIX `system()` **blocks SIGINT** while the child `sleep` runs, so Ctrl+C (SIGINT) never reached the Lua process while the monitor was waiting — the tool looked unstoppable (and without `lua-posix` the signal was effectively swallowed).
- `utils/timer.lua`: the no-socket fallback is now a **busy-wait** on `os.clock()` (still uses `socket.sleep` when luasocket is present). No `os.execute("sleep")` anymore → signals are never blocked, so Ctrl+C is delivered immediately.
- Result: Ctrl+C stops the monitor and exits the program right away (cleanly with `lua-posix`; via default SIGINT termination without it). Tradeoff: a little CPU spin during the waits, no extra install needed.

## v0.7.2 — Fix "not logged in" detection + never relaunch no-login clones

- `managers/auth.lua` rewritten: `Auth.isLoggedIn` no longer depends on one hardcoded cookie path (`app_webview/Default/Cookies`). It now **recursively greps the clone's data dir** (`/data/data/<pkg>`, or a per-instance `cookiePath` override) for a `.ROBLOSECURITY` token via root — this handles Lite/Floating/mod clones that store the session elsewhere. Short per-instance TTL cache (30s) avoids grepping every monitor cycle. Returns `true`/`false`/`nil`; `nil` (couldn't probe) keeps the old restart-safe behavior.
- **Hard anti-restart guard for no-login clones** (`managers/monitor.lua` + `managers/recovery.lua`): if `Auth.isLoggedIn(instance) == false` then the clone is treated as idle (low RSS is expected on the login screen) and is **never force-relaunched** — on the freeze-timeout path, on the healthy/recovery path (`checkAndRecover`), and inside `Recovery.relaunch`/`checkAndRecover` themselves. Reason is logged ("skipped restart/recovery ... not logged in"). Previously the guard only triggered when the transient status was `nologin` and detection could silently return `true`/`nil`, so a no-login clone could still be relaunched.

## v0.7.3 — Fix crash in Auth.lua (pcall + Shell.exec multi-return)

- `managers/auth.lua` used `local ok, out = pcall(function() return Shell.exec(cmd) end)` in `countToken` and `baseDirExists`. `Shell.exec` returns `(ok, output)`, so `pcall` returns `(true, ok, output)` — capturing only two values made `out` the boolean `Shell`'s ok, so `out:find(...)` crashed with "attempt to index a boolean value" right after launch (see errorlogs.md). Fixed both to capture the third value (`local ok, _, out = ...`), matching the rest of the codebase (optimizer/probe_log). Audited: no other `pcall(Shell.exec)` site is affected.

## v0.7.4 — Ctrl+C fix: require lua-posix, revert busy-wait

- **Root cause of Ctrl+C not stopping the program**: the SIGINT handler needs `lua-posix`, which was absent on the device → no handler installed → the default SIGINT action does not kill the program in Termux, so Ctrl+C did nothing. (Confirmed: device runs Lua PUC-Rio 5.4.8, so lua-posix is installable.)
- `managers/monitor.lua`: the SIGINT callback now calls `os.exit(0)` directly (plus sets `running=false`/`interrupted`), so Ctrl+C exits the program decisively the moment the signal is received. Clearer warning when lua-posix is missing.
- `utils/timer.lua`: **reverted the busy-wait fallback** back to `os.execute("sleep")`. The busy-wait pinned a core at 100% CPU (hot/unresponsive device) and did NOT fix Ctrl+C (which needs the handler, not non-blocked signals). With lua-posix the signal is only delayed by ≤ the current 0.25s chunk, so Ctrl+C still stops quickly.
- Requires on device: `pkg install lua-posix` (auto-installed by setup.sh for Lua PUC-Rio). README prerequisites updated.

## v0.7.5 — Ctrl+C via run.sh shell wrapper (no lua-posix needed)

- **`lua-posix` is NOT available in Termux's repos** for this setup (`pkg search posix` returns nothing), so the in-process SIGINT handler can't be used there. The real blocker is structural: the monitor loop (`managers/monitor.lua`) spends nearly all of each cycle inside `os.execute`/`io.popen` (`Status.check`, `apkManager.isActive`, `Auth.isLoggedIn`, `ProbeLog.scan`), and POSIX **blocks SIGINT while inside `system()`/`popen()`** — so the default SIGINT action (which works fine in most other tools, e.g. one-shot setup scripts that idle on `io.read`) is swallowed here.
- Added **`run.sh`**             : a one-file shell wrapper that launches `lua main.lua "$@"` as a child, installs a `trap INT TERM` that `kill -TERM` the child, and `wait`s on it. `kill(1)` from outside the process is unaffected by the child's internal SIGINT blocking, so Ctrl+C stops the engine reliably **in the same terminal** — no extra session needed. Usage: `sh run.sh [flags...]`.
- `managers/monitor.lua`: `installSignalHandler` warning updated — instead of telling the user to `pkg install lua-posix` (unavailable), it now points to `sh run.sh`. The handler itself is kept (used automatically when lua-posix exists on another device).
- README: prerequisites + quickstart + headless sections updated to run via `run.sh`; lua-posix demoted to optional. `termux-boot.sh` unchanged (boot service has no interactive terminal, so Ctrl+C is not relevant there).
- README: added "Matikan auto-boot" section (`rm ~/.termux/boot/start-rejoin.sh`) under the auto-start docs.

## v0.7.6 — AutoExecute Deploy fix: Delta path, mkdir -p, quoting

- **Root cause of AutoExecute Deploy not working**: `appAutoExecutePath` was commented out in `config/config.lua` → deploy always failed with "appAutoExecutePath is empty". Additionally, the destination path was not per-instance but the actual Delta mod autoexecute folder lives at `/sdcard/Delta/Autoexecute` (internal storage, shared across all instances) — not inside `/data/data/<pkg>/` as assumed.
- `config/config.lua` + `config/template.lua`: `appAutoExecutePath` set to `/sdcard/Delta/Autoexecute` (Delta mod default). Comment updated to reflect internal storage path.
- `managers/autoexecute.lua`: rewrote `suCopyIntoApp` — removed manual `su -c` wrapping (caused double-wrapping + quote-breaking when `Shell.exec` also wraps with `su -c`); added `mkdir -p` before `cp` to ensure the destination folder exists; single `cp` attempt with Shell.exec handling root wrapping automatically. Updated module header and `appDestBase` comments.
- `core/settings_cli.lua`: Settings menu item 7 prompt updated to show Delta path example (`/sdcard/Delta/Autoexecute`).

## v0.7.7 — AutoExecute simplified: manage /sdcard/Delta/Autoexecute directly

- **Real root-cause of Deploy still failing after v0.7.6**: the source path was **relative** (`data/autoexecute/<name>.lua`). When executed through `su -c`, the working directory is `/` (root's), not `$HOME/rejoin`, so the relative path wasn't found → `cp` failed silently → `copy_failed`; the "Deploy failed: table: 0x..." display bug (CLI printed the result table instead of its `errors` contents) masked the real reason.
- **UI simplified (`core/autoexecute_cli.lua`)**: entering menu 6 now shows the current contents of the app autoexecute folder at the top, with a simple menu below: `1) Add / 2) Edit / 3) Delete / 4) Exit`. List refreshes after each action. Remove the `deployFlow` (and its `table: 0x` bug) entirely — no deploy step anymore.
- **`managers/autoexecute.lua` rewritten** to manage the app folder directly: `dir()` returns the absolute `appAutoExecutePath`; `save()` writes straight into the folder (mkdir -p + io.open, no `cp`/`su` → immune to the relative-path-in-su bug); `list/read/remove` target the same folder. Removed obsolete `appDestBase`, `suCopyIntoApp`, `deployOne`, `deployAll` (and the global staging model).
- **Cleanup of unused staging model**: removed `autoExecuteDeployPath` from config/template/settings (Settings menu renumbered 8–15 → 7–14); removed `config/sample_AutoExecute.lua`; setup.sh no longer creates `data/autoexecute` or seeds the sample; setup help updated to `sh run.sh` and notes Delta folder + lua-posix-optional.
- Config default: `appAutoExecutePath = "/sdcard/Delta/Autoexecute"` (shared folder, internal storage, no root needed).
- README AutoExecute sections and file tree updated.

## v0.7.8 — AutoExecute menu: remove su/popen from menu path, anti-spin input

- **Root cause of "can't type anything after choosing menu 6" + messy display**: entering menu 6 ran `resolveDir()` → `Shell.exec("mkdir -p ...")` (wrapped as `su -c` via `io.popen`) **on every loop iteration, before the menu choice was read**. After that shell call the terminal's stdin could return EOF (`io.read()` → `nil`), so every choice read came back empty → the menu loop re-printed the banner+list+options in a tight spin (messy screen, keystrokes got swallowed).
- `managers/autoexecute.lua`: removed `resolveDir()` and its `Shell.exec(mkdir -p)` call entirely — **no `su`/shell anywhere in this module** now. `list()` is a pure read (`File.listDir`); the folder is created lazily on `save()` via `File.write` (os.execute/lfs mkdir, no su, no popen, and only during Add/Edit). Removed the `require("utils.shell")` usage; header comment updated.
- `core/autoexecute_cli.lua`: banner now shows the actual folder path (`AutoExecute Manager — folder: <appAutoExecutePath>`); menu choice read uses `nil`(=EOF/Ctrl+D) as **clean exit** (`break`) instead of looping; list/error output made tolerant (empty folder → hint to Add). Add/Edit/Delete flows unchanged.

## v0.7.9 — AutoExecute Edit/Delete memakai nomor, bukan nama

- Menampilkan isi folder diseragamkan jadi list **bernomor** (` 1)`, ` 2)`, ... di kedua printList menu dan saat Edit/Delete).
- Helper baru `pickFromList(promptLabel)`: list ulang bernomor, baca nomor, validasi 1..N → balikin entry terpilih; nomor invalid → pesan jelas; EOF/batal → balik tanpa aksi.
- Edit & Delete: ganti prompt ketik nama → **pilih nomor urut** dari list (nama `*.lua` dibersihkan saat tampil). Alur Add tetap minta nama (untuk script baru).

## v0.7.10 — Username di dashboard monitoring

- **Username Roblox per clone di dashboard**: `Status.printSummary` kini menampilkan `package (username)` (mis. `com.apengjers.v3 (apengjers)`), kolom Instance dilebarkan (LCOL 23 → 33) agar muat; ketika username tidak diketahui, cukup menampilkan `package`.
- **Modul baru `managers/username.lua`** (pola `auth.lua`):
  - `get(instance)` menyelesaikan username via **cookie `.ROBLOSECURITY`** → API Roblox (`https://users.roblox.com/v1/users/authenticated`), karena token cookie TIDAK mengandung username — hanya bisa di-resolve via API. Di-cache per instance (TTL 600s; hasil gagal 60s anti-hammer).
  - Fallback **scan lokal** (`shared_prefs`/`files` XML/JSON/TXT/LOG untuk key `username|userName|displayName|accountName|playerName`) jika API gagal/offline; override manual lewat field per-instance `usernamePath` (baris pertama file = username).
  - **Bukti scan** ditulis ke `data/username_scan.log` (token length, hasil API, hasil lokal) per sesi agar mudah dituning bila ada clone kosong.
- `managers/monitor.lua`: `Username.reset()` saat monitor start + `Username.prefetch(instances)` sekali sebelum loop utama (dashboard pertama sudah menampilkan username, tanpa block di tiap draw).
- `config/template.lua`: contoh instance kini punya field opsional `usernamePath = ""` + komentar. README fitur / monitoring / file tree diperbarui.

## Upcoming

- Shell Wrapper
- Android Wrapper
- Config System
- Setup Wizard