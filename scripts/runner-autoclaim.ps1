# runner-autoclaim.ps1 — bootstrap + auto-claim satu runner jadi VPS
# Urutan: RDP -> user random -> Tailscale -> Hermes (opsional) -> notifikasi
# Semua perintah di sini adalah versi yang SUDAH terbukti di runner ini.

$ErrorActionPreference = 'Continue'

$RdpUser      = if ($env:RDP_USER)    { $env:RDP_USER }    else { 'clouduser' }
$TsHostname   = if ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { 'github-windows-rdp' }
$HermesHome   = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { 'C:\Users\clouduser\AppData\Local\hermes' }
$result       = [ordered]@{ step = ''; ok = $false; ip = ''; user = $RdpUser; password = ''; hermes = 'skipped'; notes = @() }

$StatusFile = Join-Path $env:USERPROFILE 'status.txt'
function Status([string]$msg) {
    $line = '[' + (Get-Date).ToUniversalTime().ToString('HH:mm:ss') + 'Z] ' + $msg
    Write-Host $line
    try { Add-Content -Path $StatusFile -Value $line -Encoding UTF8 } catch { }
}

function New-Secret([int]$len = 16) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%^*-_=+'
    return -join (1..$len | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
}

function Send-Telegram([string]$text) {
    if (-not $env:NOTIFY_BOT_TOKEN -or -not $env:NOTIFY_CHAT_ID) {
        Write-Host '[notify] TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID kosong — notifikasi dilewati'
        return $false
    }
    try {
        $uri = "https://api.telegram.org/bot$($env:NOTIFY_BOT_TOKEN)/sendMessage"
        $resp = Invoke-RestMethod -Method Post -Uri $uri -TimeoutSec 40 -Body @{
            chat_id    = $env:NOTIFY_CHAT_ID
            text       = $text
            parse_mode = 'HTML'
        }
        Write-Host ("[notify] terkirim: ok=" + $resp.ok)
        return [bool]$resp.ok
    } catch {
        Write-Host ("[notify] GAGAL: " + $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------- 1. RDP ON
$result.step = 'enable-rdp'
Write-Host '--- enable RDP ---'
Status 'phase: rdp-enable'
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
Set-Service -Name TermService -StartupType Automatic
Restart-Service -Name TermService -Force
Start-Sleep -Seconds 5
$result.notes += ('TermService=' + (Get-Service TermService).Status)

# ------------------------------------------------- 2. USER RDP + PASSWORD
$result.step = 'create-user'
Write-Host '--- create RDP user ---'
Status 'phase: rdp-user'
$plain = New-Secret 16
$sec   = ConvertTo-SecureString $plain -AsPlainText -Force
$old   = Get-LocalUser -Name $RdpUser -ErrorAction SilentlyContinue
if ($old) { Remove-LocalUser -Name $RdpUser }
New-LocalUser -Name $RdpUser -Password $sec -FullName 'Cloud RDP User' `
    -Description 'GitHub Actions RDP User' -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
Add-LocalGroupMember -Group 'Administrators' -Member $RdpUser -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $RdpUser -ErrorAction SilentlyContinue
$result.password = $plain
$result.notes += 'rdp-user-ok'

# ----------------------------------------------------------- 3. TAILSCALE
$result.step = 'tailscale'
Write-Host '--- tailscale ---'
Status 'phase: tailscale'
$ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (-not (Test-Path $ts)) {
    $installer = Join-Path $env:TEMP 'tailscale-setup.exe'
    Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $installer -UseBasicParsing
    Start-Process -FilePath $installer -ArgumentList '/quiet' -Wait
    Start-Sleep -Seconds 10
}
if (-not (Test-Path $ts)) {
    $result.notes += 'TAILSCALE_INSTALL_FAILED'
    Write-Host 'tailscale gagal terpasang'
} elseif (-not $env:TS_AUTHKEY) {
    $result.notes += 'TS_AUTHKEY_MISSING'
    Write-Host 'TS_AUTHKEY tidak ada di secrets'
} else {
    & $ts up --authkey="$($env:TS_AUTHKEY)" --hostname="$TsHostname" --accept-routes
    Start-Sleep -Seconds 10
    $result.ip = (& $ts ip -4 | Select-Object -First 1)
    $result.notes += ('tailscale=' + ($(if ($result.ip) { 'up' } else { 'no-ip' })))
}
$result.ok = [bool]$result.ip

# -------------------------------------------------------------- 4. HERMES
$hasState = [bool]($env:HERMES_CONFIG_B64 -or $env:HERMES_ENV_B64 -or $env:HERMES_CONF_B64)
if ($hasState) {
    $result.step = 'hermes'
    Write-Host '--- install hermes ---'
    Status 'phase: install-hermes START'
    $env:HERMES_NONINTERACTIVE = '1'
    $env:HERMES_ACCEPT_HOOKS = '1'
    $logDir = Join-Path $env:USERPROFILE 'hermes-install'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    # uv wajib ada sebelum installer Hermes jalan. Di runner ini installer uv milik
    # Hermes GAGAL: "The 'Get-ExecutionPolicy' command ... module could not be loaded"
    # (modul Microsoft.PowerShell.Security tidak termuat di proses Start-Process),
    # jadi uv dipasang manual dari zip rilis resmi astral-sh.
    $binDir = Join-Path $HermesHome 'bin'
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
    if (-not (Test-Path (Join-Path $binDir 'uv.exe'))) {
        Status 'phase: uv manual install'
        try {
            $uvZip = Join-Path $env:TEMP 'uv-win.zip'
            Invoke-WebRequest -Uri 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip' -OutFile $uvZip -UseBasicParsing
            Expand-Archive -Path $uvZip -DestinationPath $binDir -Force
            Status ('uv.exe terpasang: ' + (Test-Path (Join-Path $binDir 'uv.exe')))
        } catch {
            Status ('uv manual GAGAL: ' + $_.Exception.Message)
        }
    } else {
        Status 'uv.exe sudah ada'
    }

    $instPs1 = Join-Path $env:TEMP 'hermes-install-run.ps1'
    $logOut = Join-Path $logDir ('installer-' + (Get-Date -Format 'HHmmss') + '.log')
    @'
$env:HERMES_NONINTERACTIVE = '1'
$env:HERMES_ACCEPT_HOOKS = '1'
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules"
$ErrorActionPreference = 'Continue'
Write-Output "installer wrapper start $(Get-Date -Format o)"
try {
    $body = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1' -UseBasicParsing
    & ([scriptblock]::Create($body.Content)) -SkipSetup
    Write-Output ("installer exit=" + $LASTEXITCODE)
} catch {
    Write-Output ("INSTALLER THREW: " + $_.Exception.Message)
    Write-Output $_.ScriptStackTrace
}
Write-Output "installer wrapper done $(Get-Date -Format o)"
'@ | Set-Content -Path $instPs1 -Encoding UTF8
    try {
        $p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instPs1) `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $logOut -RedirectStandardError ($logOut + '.err')
        $done = $p.WaitForExit(900000)   # 15 menit cap
        if (-not $done) {
            try { $p.Kill() } catch { }
            $result.notes += 'installer-timeout-15m'
            Status 'phase: install-hermes TIMEOUT 15 menit -> proses dihentikan, lanjut'
        } else {
            $result.notes += ('installer-exit=' + $p.ExitCode)
            Status ('phase: install-hermes selesai exit=' + $p.ExitCode)
        }
    } catch {
        $result.notes += 'HERMES_INSTALL_FAILED'
        Status ('phase: install-hermes GAGAL: ' + $_.Exception.Message)
    }
    Status ('hermes.exe ada: ' + (Test-Path (Join-Path $HermesHome 'bin\hermes.exe')))

    if (-not (Test-Path $HermesHome)) { New-Item -ItemType Directory -Path $HermesHome -Force | Out-Null }

    # restore dari secret: base64 -> tar.gz -> HERMES_HOME
    function Restore-Blob([string]$b64, [string]$tag) {
        if (-not $b64) { return }
        try {
            $tar = Join-Path $env:TEMP ("hermes-$tag.tar.gz")
            [System.IO.File]::WriteAllBytes($tar, [Convert]::FromBase64String($b64))
            & "$env:SystemRoot\system32\tar.exe" -xzf $tar -C $HermesHome
            Write-Host ("restore $tag exit=" + $LASTEXITCODE)
            $script:result.notes += "restored-$tag"
        } catch {
            Write-Host ("restore $tag gagal: " + $_.Exception.Message)
            $script:result.notes += "RESTORE_FAILED-$tag"
        }
    }
    Restore-Blob $env:HERMES_CONFIG_B64 'full'
    Restore-Blob $env:HERMES_ENV_B64 'env'
    Restore-Blob $env:HERMES_CONF_B64 'conf'

    # ---- rotasi API key b.ai: pilih key yang hidup, plus task auto-rotate tiap 30 menit
    Status 'phase: bai-key-rotate'
    $rotSrc = Join-Path $PSScriptRoot 'bai-key-rotate.ps1'
    $rotDst = Join-Path $env:USERPROFILE 'bai-key-rotate.ps1'
    $keysFile = Join-Path $env:USERPROFILE 'bai_keys.txt'
    try {
        if ($env:BAI_KEYS_B64) {
            $txt = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:BAI_KEYS_B64))
            [System.IO.File]::WriteAllText($keysFile, $txt)
            $n = (Get-Content $keysFile | Where-Object { $_ -match '^sk-' }).Count
            $result.notes += "keys-file=$n"
        }
        if (Test-Path $rotSrc) { Copy-Item $rotSrc $rotDst -Force }
        if ((Test-Path $rotDst) -and (Test-Path $keysFile)) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $rotDst -HermesHome $HermesHome | Write-Host
            $result.notes += ('key-rotate-exit=' + $LASTEXITCODE)
            & schtasks.exe /Create /TN 'HermesKeyRotate' /TR "powershell -NoProfile -ExecutionPolicy Bypass -File `"$rotDst`"" /SC MINUTE /MO 30 /RU SYSTEM /RL HIGHEST /F | Out-Null
            $result.notes += 'key-rotate-task=30min'
        } else {
            $result.notes += 'key-rotate=skipped'
        }
    } catch {
        $result.notes += 'KEY_ROTATE_ERROR'
        Write-Host ('rotasi key gagal: ' + $_.Exception.Message)
    }

    # token bot: kalau HERMES_TG_TOKEN diisi, pakai itu. Kalau tidak, biarkan
    # token dari .env hasil restore — handover yang menjamin cuma satu poller hidup.
    $envFile = Join-Path $HermesHome '.env'
    $hasBotToken = $false
    if (Test-Path $envFile) {
        $lines = Get-Content $envFile
        if ($env:HERMES_TG_TOKEN) {
            $lines = $lines | ForEach-Object {
                if ($_ -match '^TELEGRAM_BOT_TOKEN=') { 'TELEGRAM_BOT_TOKEN=' + $env:HERMES_TG_TOKEN } else { $_ }
            }
            Set-Content -Path $envFile -Value $lines -Encoding UTF8
        }
        $hasBotToken = [bool](Get-Content $envFile | Where-Object { $_ -match '^TELEGRAM_BOT_TOKEN=\S' })
    }

    $cmd = Join-Path $env:USERPROFILE 'hermes_gateway.cmd'
    @"
@echo off
set HERMES_HOME=$HermesHome
if not exist "%HERMES_HOME%\logs" mkdir "%HERMES_HOME%\logs"
cd /d "%HERMES_HOME%"
"%HERMES_HOME%\bin\hermes.exe" gateway run --accept-hooks >> "%HERMES_HOME%\logs\gateway-task.log" 2>&1
"@ | Set-Content -Path $cmd -Encoding ASCII

    foreach ($f in @('gateway.pid', 'gateway.lock', 'gateway.sock')) {
        $p = Join-Path $HermesHome $f
        if (Test-Path $p) { Remove-Item $p -Force }
    }
    & schtasks.exe /Create /TN 'HermesVpsGateway' /TR $cmd /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
    if ($env:HERMES_START_NOW -eq '0') {
        $result.hermes = 'standby-handover'
    } elseif (-not $hasBotToken) {
        $result.hermes = 'no-bot-token-in-env'
    } else {
        & schtasks.exe /Run /TN 'HermesVpsGateway' | Out-Null
        Start-Sleep -Seconds 35
        $live = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'gateway' }
        $result.hermes = if ($live) { 'gateway-running' } else { 'gateway-not-rising' }
    }
    $result.notes += ('hermes=' + $result.hermes)
}

# ---------------------------------------------------------- 5. AUTO CLAIM
$result.step = 'notify'
$msg = @()
$msg += '<b>VPS RUNNER BARU — AUTO CLAIM</b>'
Status 'phase: notify'
$msg += ''
$msg += "RDP  : <code>$($result.ip):3389</code>"
$msg += "User : <code>$($result.user)</code>"
$msg += "Pass : <code>$($result.password)</code>"
$msg += "Hermes: <code>$($result.hermes)</code>"
$msg += "Runner: <code>$env:RUNNER_NAME</code>"
$msg += "Repo  : <code>$env:GITHUB_REPOSITORY</code>"
$msg += "Start : $((Get-Date).ToUniversalTime().ToString('s'))Z"
$msg += "Note  : $($result.notes -join ', ')"
$body = ($msg -join "`n")
Send-Telegram $body | Out-Null

Write-Host ''
Write-Host '================= AUTO CLAIM SUMMARY ================='
Write-Host ("ip        : " + $result.ip)
Write-Host ("user      : " + $result.user)
Write-Host ("password  : " + ($result.password.Substring(0,4) + '***') + ' <-- lengkap cuma di Telegram')
Write-Host ("hermes    : " + $result.hermes)
Write-Host ("notes     : " + ($result.notes -join ', '))
Write-Host '======================================================'
