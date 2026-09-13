-- Rejoin Heartbeat client — jalankan di DALAM game Roblox (via Delta AutoExecute).
--
-- Kirim sinyal "saya masih hidup" setiap 10 detik ke server rejoin di Termux
-- (http://127.0.0.1:8080/heartbeat). Kunci file/identitas = username akun, jadi
-- Termux langsung tahu package mana yang freeze ketika sinyal berhenti.
--
-- WAJIB: executor Delta harus punya fungsi raw `request`/`http_request`.
-- https://HttpService:PostAsync TIDAK bisa (di-proxy server Roblox, bukan device).
--
-- Cara pasang:
--   sh run.sh -> 6) AutoExecute Manager -> 1) Add -> ketik/rename script ini
-- Nama file bebas (mis. heartbeat.lua). Delta auto-run tiap launch.
--
-- Kalau request pakai key lain (mis. URL / url), bagian BODY_REQ di bawah diubah,
-- atau pakai bentuk request({ URL=..., url=... }) — kode sudah coba keduanya.

local Http = game:GetService("HttpService")
local KEY = game:GetService("Players") and game:GetService("Players").LocalPlayer
    and game:GetService("Players").LocalPlayer.Name or "unknown"

local URL = "http://127.0.0.1:8080/heartbeat"

local function send()
    local body = Http:JSONEncode({ app = KEY, acc = KEY })
    local ok, r = pcall(function()
        if request then
            -- coba kedua bentuk argument (Url / URL / url)
            local okReq, res = pcall(request, {
                Url = URL, Method = "POST",
                Headers = { ["Content-Type"] = "application/json" }, Body = body,
            })
            if not okReq and type(res) == "table" then
                request({ URL = URL, Method = "POST",
                          Headers = { ["Content-Type"] = "application/json" }, Body = body })
            elseif not okReq and type(request) == "function" then
                request({ url = URL, method = "POST", body = body })
            end
        elseif http_request then
            http_request({ Url = URL, Method = "POST",
                           Headers = { ["Content-Type"] = "application/json" }, Body = body })
        end
    end)
end

while true do
    pcall(send)
    task.wait(10)
end