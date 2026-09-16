# gateway-handover.ps1 — ambil alih bot Telegram di runner baru
#
# Kenapa perlu: satu bot Telegram cuma boleh di-poll SATU proses.
# Kalau runner baru langsung menyalakan gateway sementara runner lama masih hidup,
# dua-duanya kena `409 Conflict: terminated by other getUpdates request` dan bot flapping.
#
# Jadi runner baru menunggu sampai tidak ada lagi peer Tailscale lain bernama
# github-windows-rdp* yang online (artinya VM lama sudah mati & keluar dari tailnet),
# baru menyalakan gateway Hermes di sini. Dengan begitu bot pindah host tanpa konflik.

param(
    [int]$MaxWaitMinutes = 240,
    [int]$PollSeconds = 30
)

$ErrorActionPreference = 'Continue'
$TaskName = 'HermesVpsGateway'
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { 'C:\Users\clouduser\AppData\Local\hermes' }

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

function Get-OldRunners {
    $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
    if (-not (Test-Path $ts)) { return @() }
    try { $json = & $ts status --json | ConvertFrom-Json } catch { return @() }
    $selfName = $json.Self.DNSName
    $out = @()
    foreach ($p in $json.Peer.PSObject.Properties) {
        $n = $p.Value
        if ($n.Online -and $n.DNSName -ne $selfName -and $n.HostName -like 'github-windows-rdp*') {
            $out += ($n.HostName + ' [' + ($n.TailscaleIPs -join ',') + ']')
        }
    }
    return $out
}

function Start-Gateway {
    Write-Host '--- menyalakan gateway Hermes ---'
    & schtasks.exe /Run /TN $TaskName | Out-Null
    Start-Sleep -Seconds 40
    $live = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'gateway' }
    $state = 'gateway-not-rising'
    if ($live) { $state = 'gateway-running pid=' + (($live | ForEach-Object { $_.ProcessId }) -join ',') }
    $statusFile = Join-Path $HermesHome 'gateway_state.json'
    $hub = ''
    if (Test-Path $statusFile) { $hub = (Get-Content $statusFile -Raw) }
    Send-Telegram ("<b>BOT PINDAH HOST</b>`n" +
        "Runner : <code>$env:RUNNER_NAME</code>`n" +
        "State  : <code>$state</code>`n" +
        "Waktu  : $((Get-Date).ToUniversalTime().ToString('s'))Z`n" +
        "<i>Gateway sekarang polling dari runner baru. Runner lama sudah mati.</i>")
    Write-Host ("hasil: " + $state)
    return $state
}

$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
Write-Host ("=== handover start (max " + $MaxWaitMinutes + " menit) " + (Get-Date -Format o) + " ===")

while ((Get-Date) -lt $deadline) {
    $old = Get-OldRunners
    if ($old.Count -eq 0) {
        Write-Host 'tidak ada runner lama yang hidup -> ambil alih'
        Start-Gateway | Out-Null
        exit 0
    }
    Write-Host ("[" + (Get-Date -Format HH:mm:ss) + "] masih ada runner lain: " + ($old -join ' | ') + " -> tunggu " + $PollSeconds + "s")
    Start-Sleep -Seconds $PollSeconds
}

Write-Host 'batas tunggu habis — ambil alih juga (lebih baik daripada bot mati total)'
Start-Gateway | Out-Null
