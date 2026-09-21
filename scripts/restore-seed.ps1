# restore-seed.ps1 — cold-fallback: pakai seed backup terenkripsi yang di-commit di repo
# Dipanggil runner-restore-backup.ps1 kalau artifact GitHub tidak ada (run pertama / expired).
# Seed = state host sebelumnya yang di-commit terenkripsi (seed/hermes-state.tar.gz.enc).
param([string]$SeedPath = (Join-Path $PSScriptRoot '..\seed\hermes-state.tar.gz.enc'))
$ErrorActionPreference = 'Continue'
function Status([string]$msg) {
    $line = '[restore-seed] ' + $msg
    Write-Host $line
    try { Add-Content -Path (Join-Path $env:USERPROFILE 'status.txt') -Value $line -Encoding UTF8 } catch { }
}
if (-not $env:BACKUP_KEY) { Status 'BACKUP_KEY kosong -> seed dilewati'; exit 0 }
if (-not (Test-Path $SeedPath)) { Status "seed tidak ada: $SeedPath"; exit 0 }
$tarGz = Join-Path $env:TEMP 'hermes-seed.tar.gz'
$openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
if (-not $openssl) { $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe' }
$p = Start-Process -FilePath $openssl -ArgumentList @('enc','-d','-aes-256-cbc','-pbkdf2',
    '-pass',"pass:$($env:BACKUP_KEY)",'-in',$SeedPath,'-out',$tarGz) -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0 -or -not (Test-Path $tarGz)) { Status ("decrypt seed gagal exit=" + $p.ExitCode); exit 0 }
$stage = Join-Path $env:TEMP 'hermes-seed-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
& "$env:SystemRoot\system32\tar.exe" -xzf $tarGz -C $stage 2>$null
$src = Join-Path $stage 'hermes-state'
if (-not (Test-Path $src)) { Status 'seed tidak berisi hermes-state/'; exit 0 }
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { 'C:\Users\clouduser\AppData\Local\hermes' }
if (-not (Test-Path $HermesHome)) { New-Item -ItemType Directory -Path $HermesHome -Force | Out-Null }
Copy-Item (Join-Path $src '*') $HermesHome -Recurse -Force
Set-Content -Path (Join-Path $HermesHome '.restored-from-artifact') -Value (Get-Date -Format o) -Encoding UTF8
Status ('seed dipulihkan: ' + ((Get-ChildItem $src | Select-Object -ExpandProperty Name) -join ', '))
exit 0
