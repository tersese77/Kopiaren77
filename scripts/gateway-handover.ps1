# gateway-handover.ps1 — ambil alih bot Telegram di runner baru, tanpa 409
#
# MASALAH yang diperbaiki: satu bot Telegram cuma boleh di-poll SATU proses.
# Kalau runner baru menyalakan gateway sementara runner lama masih polling,
# dua-duanya kena `409 Conflict: terminated by other getUpdates request` dan bot flapping.
#
# CARA LAMA (salah): menunggu "tidak ada peer tailnet github-windows-rdp* yang online".
# Itu keliru dua kali:
#   - field HostName di `tailscale status --json` TIDAK punya sufiks (-50/-51);
#     sufiksnya cuma ada di DNSName, jadi pencocokan nama salah sasaran
#   - ada node runner lain (mis. rdp-49) yang online terus walau bukan dia yang
#     memegang bot -> handover nunggu kelamaan / ambil alih di waktu yang salah
#
# CARA SEKARANG (benar): dua syarat, dicek berurutan.
#   1. kalau $env:HANDOVER_FROM diisi (mis. github-windows-rdp-50), tunggu node
#      pendahulu itu benar-benar hilang dari tailnet. Deterministik, tanpa tebak-tebakan.
#   2. tanya Telegram lewat getUpdates, dan WAJIB $RequiredCleanProbes kali bersih
#      berturut-turut (satu probe bisa nyempil di celah antar long-poll -> false positive,
#      sudah kejadian saat uji: probe tunggal balas 200 padahal poller lain hidup).
#   Pakai offset=-1 supaya tidak meng-acknowledge (tidak menghilangkan) update apa pun.

param(
    [int]$MaxWaitMinutes = 300,
    [int]$PollSeconds = 120,
    [int]$ProbeTimeoutSec = 25,
    [int]$RequiredCleanProbes = 3,
    [switch]$ProbeOnly
)

$ErrorActionPreference = 'Continue'
$TaskName = 'HermesVpsGateway'
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { 'C:\Users\clouduser\AppData\Local\hermes' }
$envFile = Join-Path $HermesHome '.env'

function Send-Telegram([string]$text) {
    if (-not $env:NOTIFY_BOT_TOKEN -or -not $env:NOTIFY_CHAT_ID) { return }
    try {
        Invoke-RestMethod -Method Post -TimeoutSec 40 `
            -Uri "https://api.telegram.org/bot$($env:NOTIFY_BOT_TOKEN)/sendMessage" `
            -Body @{ chat_id = $env:NOTIFY_CHAT_ID; text = $text; parse_mode = 'HTML' } | Out-Null
    } catch {
        Write-Host ("[notify] gagal: " + $_.Exception.Message)
    }
}

function Get-BotToken {
    if (-not (Test-Path $envFile)) { return $null }
    $l = Get-Content $envFile | Where-Object { $_ -match '^TELEGRAM_BOT_TOKEN=\S' } | Select-Object -First 1
    if (-not $l) { return $null }
    return ($l -split '=', 2)[1].Trim()
}

# $true = ada poller lain, $false = tidak ada, $null = tidak bisa dipastikan
function Test-OtherPoller([string]$token) {
    $uri = "https://api.telegram.org/bot$token/getUpdates?timeout=0&limit=1&offset=-1"
    try {
        Invoke-RestMethod -Uri $uri -TimeoutSec $ProbeTimeoutSec | Out-Null
        return $false
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 409) { return $true }
        Write-Host ("[probe] tidak pasti (code=" + $code + "): " + $_.Exception.Message)
        return $null
    }
}

function Test-PredecessorOnline {
    if (-not $env:HANDOVER_FROM) { return $false }
    $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
    if (-not (Test-Path $ts)) { return $false }
    try { $json = & $ts status --json | ConvertFrom-Json } catch { return $false }
    $want = $env:HANDOVER_FROM.TrimEnd('.')
    foreach ($p in $json.Peer.PSObject.Properties) {
        $n = $p.Value
        if ($n.Online -and $n.DNSName -and ($n.DNSName -split '\.')[0] -eq $want) { return $true }
    }
    return $false
}

function Start-Gateway {
    Write-Host '--- menyalakan gateway Hermes ---'
    & schtasks.exe /Run /TN $TaskName | Out-Null
    Start-Sleep -Seconds 45
    $live = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'gateway' }
    $state = 'gateway-not-rising'
    if ($live) { $state = 'gateway-running pid=' + (($live | ForEach-Object { $_.ProcessId }) -join ',') }
    Send-Telegram ("<b>BOT PINDAH HOST</b>`n" +
        "Runner : <code>$env:RUNNER_NAME</code>`n" +
        "State  : <code>$state</code>`n" +
        "Waktu  : $((Get-Date).ToUniversalTime().ToString('s'))Z`n" +
        "<i>Gateway sekarang polling dari runner ini.</i>")
    Write-Host ("hasil: " + $state)
}

$token = Get-BotToken
if (-not $token) {
    Write-Host 'TIDAK ADA TELEGRAM_BOT_TOKEN di .env — gateway tidak bisa dinyalakan'
    Send-Telegram "<b>HANDOVER GAGAL</b>`nRunner <code>$env:RUNNER_NAME</code>: .env hasil restore tidak berisi TELEGRAM_BOT_TOKEN."
    exit 1
}
Write-Host ("token bot dimuat: len=" + $token.Length)

if ($ProbeOnly) {
    $r = Test-OtherPoller $token
    if ($r -eq $true) { Write-Host 'probe-only: ADA poller lain (409)' }
    elseif ($r -eq $false) { Write-Host 'probe-only: TIDAK ada poller lain (200)' }
    else { Write-Host 'probe-only: tidak pasti' }
    exit 0
}

$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
Write-Host ("=== handover start (max " + $MaxWaitMinutes + " menit) " + (Get-Date -Format o) + " ===")
if ($env:HANDOVER_FROM) { Write-Host ("predecessor yang ditunggu: " + $env:HANDOVER_FROM) }

$clean = 0
while ((Get-Date) -lt $deadline) {
    if (Test-PredecessorOnline) {
        $clean = 0
        Write-Host ("[" + (Get-Date -Format HH:mm:ss) + "] node pendahulu " + $env:HANDOVER_FROM + " masih online -> tunggu " + $PollSeconds + "s")
        Start-Sleep -Seconds $PollSeconds
        continue
    }

    $other = Test-OtherPoller $token
    if ($other -eq $true) {
        $clean = 0
        Write-Host ("[" + (Get-Date -Format HH:mm:ss) + "] ada poller lain (409) -> runner lama masih pegang bot, tunggu " + $PollSeconds + "s")
        Start-Sleep -Seconds $PollSeconds
        continue
    }
    if ($other -eq $null) {
        $clean = 0
        Write-Host ("[" + (Get-Date -Format HH:mm:ss) + "] probe tidak pasti -> ulangi 20s")
        Start-Sleep -Seconds 20
        continue
    }

    $clean++
    Write-Host ("[" + (Get-Date -Format HH:mm:ss) + "] probe bersih " + $clean + "/" + $RequiredCleanProbes)
    if ($clean -ge $RequiredCleanProbes) {
        Write-Host 'tidak ada poller lain setelah beberapa probe -> ambil alih sekarang'
        Start-Gateway
        exit 0
    }
    Start-Sleep -Seconds 30
}

Write-Host 'batas tunggu habis — ambil alih juga (lebih baik daripada bot mati total)'
Start-Gateway
