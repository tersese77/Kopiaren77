# bai-key-rotate.ps1 — pilih API key b.ai yang masih hidup, lalu tulis ke .env Hermes
#
# Kenapa: kalau key yang dipakai kena limit/429/di-revoke, gateway Hermes mati
# (model call gagal). Script ini memilih key yang benar-benar bisa dipakai, bukan
# cuma "ada di daftar": tiap key diuji dua tahap — GET /models lalu chat completion
# minimal. Key pertama yang lolos dua tahap itu yang dipasang.
#
# Sumber key (digabung, urut prioritas):
#   1. $env:BAI_KEYS      — newline/koma/space separated (cocok untuk GitHub Secret)
#   2. file -KeysFile     — default: %USERPROFILE%\bai_keys.txt lalu C:\Users\clouduser\bai_keys.txt
#   3. key yang sekarang ada di .env (dites ulang; kalau masih hidup dipakai lagi)
#
# Bukan dry-run oleh default: kalau ada key yang lolos, .env langsung ditulis.
# Pakai -DryRun untuk cuma menguji tanpa menulis.

param(
    [string]$KeysFile = '',
    [string]$Model = 'deepseek-v4.1-flash',
    [string]$BaseUrl = 'https://api.b.ai/v1',
    [string]$HermesHome = $env:HERMES_HOME,
    [int]$ProbeTimeoutSec = 15,
    [int]$MaxProbe = 0,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
if (-not $HermesHome) { $HermesHome = 'C:\Users\clouduser\AppData\Local\hermes' }
$envFile = Join-Path $HermesHome '.env'

function Mask([string]$k) {
    if (-not $k) { return '(kosong)' }
    if ($k.Length -le 12) { return '***' }
    return $k.Substring(0, 6) + '...' + $k.Substring($k.Length - 4)
}

function Get-CurrentKey {
    if (-not (Test-Path $envFile)) { return $null }
    $l = Get-Content $envFile | Where-Object { $_ -match '^BAI_API_KEY=\S' } | Select-Object -First 1
    if (-not $l) { return $null }
    return ($l -split '=', 2)[1].Trim()
}

# $true = key hidup, $false = mati/limit, $null = tidak bisa dipastikan (mis. jaringan)
function Test-Key([string]$key) {
    $headers = @{ Authorization = "Bearer $key" }
    try {
        Invoke-RestMethod -Uri "$BaseUrl/models" -Headers $headers -TimeoutSec $ProbeTimeoutSec | Out-Null
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 200) { }
        elseif ($null -eq $code) { return $null }
        else { return $false }
    }

    # max_tokens minimal 3 — b.ai menolak <=2 dengan HTTP 400
    $body = @{ model = $Model; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 3 } | ConvertTo-Json -Depth 5
    try {
        Invoke-RestMethod -Method Post -Uri "$BaseUrl/chat/completions" -Headers $headers `
            -ContentType 'application/json' -Body $body -TimeoutSec $ProbeTimeoutSec | Out-Null
        return $true
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($null -eq $code) { return $null }   # network hiccup -> jangan buang key ini
        Write-Host ("    chat probe gagal: HTTP " + $code)
        return $false
    }
}

function Set-EnvKey([string]$key) {
    # tulis sambil mempertahankan line-ending asli (LF/CRLF) + status BOM,
    # supaya .env tidak "berubah bentuk" cuma karena rotasi key
    $bytes = [System.IO.File]::ReadAllBytes($envFile)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $raw = [System.IO.File]::ReadAllText($envFile)
    $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    if ($raw -match '(?m)^BAI_API_KEY=.*$') {
        $raw = [regex]::Replace($raw, '(?m)^BAI_API_KEY=.*$', 'BAI_API_KEY=' + $key)
    } else {
        if (-not $raw.EndsWith($nl)) { $raw += $nl }
        $raw += ('BAI_API_KEY=' + $key + $nl)
    }
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($envFile, $raw, $enc)
}

# ---- kumpulkan kandidat
$cands = @()
if ($env:BAI_KEYS) { $cands += ($env:BAI_KEYS -split '[\s,]+' | Where-Object { $_ }) }
if ($env:BAI_KEYS_B64) {
    try {
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:BAI_KEYS_B64))
        $cands += ($decoded -split '[\s,]+' | Where-Object { $_ })
    } catch { Write-Host 'BAI_KEYS_B64 tidak bisa di-decode, dilewati' }
}
if (-not $KeysFile) {
    foreach ($p in @((Join-Path $env:USERPROFILE 'bai_keys.txt'), 'C:\Users\clouduser\bai_keys.txt')) {
        if (Test-Path $p) { $KeysFile = $p; break }
    }
}
if ($KeysFile -and (Test-Path $KeysFile)) {
    $cands += (Get-Content $KeysFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
$cur = Get-CurrentKey
if ($cur) { $cands = @($cur) + $cands }

$cands = $cands | Where-Object { $_ -match '^sk-[0-9A-Za-z]{10,}$' } | Select-Object -Unique
if ($MaxProbe -gt 0) { $cands = $cands | Select-Object -First $MaxProbe }

Write-Host ("=== bai key rotate === home=" + $HermesHome)
Write-Host ("file key    : " + $(if ($KeysFile) { $KeysFile } else { '(tidak ada file, hanya env/current)' }))
Write-Host ("kandidat    : " + $cands.Count + " key")
Write-Host ("key di .env : " + (Mask $cur))

$i = 0
foreach ($k in $cands) {
    $i++
    $r = Test-Key $k
    if ($r -eq $true) {
        Write-Host ("  [" + $i + "/" + $cands.Count + "] " + (Mask $k) + " -> HIDUP")
        if ($DryRun) { Write-Host '  -DryRun: .env tidak diubah'; exit 0 }
        Set-EnvKey $k
        Write-Host ("  BAI_API_KEY ditulis ke .env -> " + (Mask $k))
        exit 0
    } elseif ($r -eq $false) {
        Write-Host ("  [" + $i + "/" + $cands.Count + "] " + (Mask $k) + " -> mati/limit")
    } else {
        Write-Host ("  [" + $i + "/" + $cands.Count + "] " + (Mask $k) + " -> tidak bisa dipastikan (jaringan)")
    }
}

Write-Host 'TIDAK ADA key yang lolos uji — .env dibiarkan apa adanya'
exit 1
