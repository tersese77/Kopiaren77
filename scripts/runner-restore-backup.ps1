# runner-restore-backup.ps1 — pulihkan state Hermes dari backup artifact host sebelumnya.
# Sumber: artifact GitHub "hermes-state-backup" TERBARU (resolved via API pakai GITHUB_TOKEN).
# Kunci dekripsi: secret BACKUP_KEY (AES-256-CBC + PBKDF2).
# Gagal di semua tahap TIDAK menggagalkan bootstrap -> jalur HERMES_ENV_B64/CONF_B64 tetap jalan.
$ErrorActionPreference = 'Continue'
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { 'C:\Users\clouduser\AppData\Local\hermes' }
$Repo = $env:GITHUB_REPOSITORY
if (-not $Repo -and $env:RESTORE_REPO) { $Repo = $env:RESTORE_REPO }

function Status([string]$msg) {
    $line = '[restore-backup] ' + $msg
    Write-Host $line
    try { Add-Content -Path (Join-Path $env:USERPROFILE 'status.txt') -Value $line -Encoding UTF8 } catch { }
}

if (-not $env:BACKUP_KEY) { Status 'BACKUP_KEY kosong -> restore dilewati'; exit 0 }

$enc = $null
try {
    # 1. URL eksplisit (opsional, override)
    if (-not $enc -and $env:RESTORE_BACKUP_URL -and $env:GH_TOKEN) {
        try {
            $tmpZip = Join-Path $env:TEMP 'backup-artifact.zip'
            $h = @{ Authorization = "Bearer $($env:GH_TOKEN)"; Accept = 'application/vnd.github+json' }
            Invoke-WebRequest -Uri $env:RESTORE_BACKUP_URL -Headers $h -OutFile $tmpZip -UseBasicParsing -TimeoutSec 300
            $tmpDir = Join-Path $env:TEMP 'backup-artifact'
            if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
            Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
            $found = Get-ChildItem $tmpDir -Recurse -Filter 'hermes-state.tar.gz.enc' | Select-Object -First 1
            if ($found) { $enc = $found.FullName; Status "backup via URL eksplisit: $enc" }
        } catch { Status ("URL eksplisit gagal: " + $_.Exception.Message) }
    }
    # 2. Resolve artifact TERBARU dari repo ini via API
    if (-not $enc -and $env:GH_TOKEN -and $Repo) {
        try {
            $h = @{ Authorization = "Bearer $($env:GH_TOKEN)"; Accept = 'application/vnd.github+json' }
            $u = "https://api.github.com/repos/$Repo/actions/artifacts?name=hermes-state-backup&per_page=1"
            $list = Invoke-RestMethod -Method Get -Uri $u -Headers $h -TimeoutSec 60
            $art = $list.artifacts | Select-Object -First 1
            if ($art) {
                Status ("artifact ditemukan: id=" + $art.id + " expired=" + $art.expired + " size=" + [math]::Round($art.size_in_bytes/1MB,1) + "MB dibuat=" + $art.created_at)
                if (-not $art.expired) {
                    $tmpZip = Join-Path $env:TEMP 'backup-artifact.zip'
                    Invoke-WebRequest -Uri $art.archive_download_url -Headers $h -OutFile $tmpZip -UseBasicParsing -TimeoutSec 600
                    $tmpDir = Join-Path $env:TEMP 'backup-artifact'
                    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
                    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
                    $found = Get-ChildItem $tmpDir -Recurse -Filter 'hermes-state.tar.gz.enc' | Select-Object -First 1
                    if ($found) { $enc = $found.FullName; Status "backup via artifact terbaru: $enc" }
                } else { Status 'artifact terbaru sudah expired -> lewati' }
            } else { Status 'tidak ada artifact backup di repo ini (run pertama?)' }
        } catch { Status ("resolve artifact gagal: " + $_.Exception.Message) }
    }
    # 3. Backup lokal di host yang sama (fallback terakhir)
    if (-not $enc) {
        $local = Join-Path $env:TEMP 'hermes-state.tar.gz.enc'
        if (Test-Path $local) { $enc = $local; Status "backup lokal ditemukan: $enc" }
    }
    if (-not $enc) { Status 'TIDAK ADA backup -> lanjut bootstrap tanpa restore'; exit 0 }

    # 4. Dekripsi AES-256-CBC + PBKDF2
    $tarGz = Join-Path $env:TEMP 'hermes-state.tar.gz'
    $openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
    if (-not $openssl) { $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe' }
    if (-not (Test-Path $openssl)) { throw 'openssl tidak ditemukan' }
    $p = Start-Process -FilePath $openssl -ArgumentList @('enc','-d','-aes-256-cbc','-pbkdf2',
        '-pass',"pass:$($env:BACKUP_KEY)",'-in',$enc,'-out',$tarGz) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -or -not (Test-Path $tarGz)) { throw "decrypt exit=$($p.ExitCode) (kunci BACKUP_KEY salah atau file korup)" }

    # 5. Ekstrak ke staging lalu pindahkan isinya ke HERMES_HOME (mapping hermes-state/* -> HERMES_HOME/*)
    $stage = Join-Path $env:TEMP 'hermes-restore-stage'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    & "$env:SystemRoot\system32\tar.exe" -xzf $tarGz -C $stage 2>$null
    if ($LASTEXITCODE -ne 0) { throw "tar extract exit=$LASTEXITCODE" }
    $src = Join-Path $stage 'hermes-state'
    if (-not (Test-Path $src)) { throw ' struktur backup tidak berisi hermes-state/' }
    if (-not (Test-Path $HermesHome)) { New-Item -ItemType Directory -Path $HermesHome -Force | Out-Null }
    Copy-Item (Join-Path $src '*') $HermesHome -Recurse -Force
    # marker: memberi tahu bootstrap agar TIDAK menimpa .env/config.yaml dengan B64 stale
    Set-Content -Path (Join-Path $HermesHome '.restored-from-artifact') -Value (Get-Date -Format o) -Encoding UTF8
    $names = (Get-ChildItem $src | Select-Object -ExpandProperty Name) -join ', '
    Status ("restore OK: " + $names)
    exit 0
} catch {
    Status ("RESTORE GAGAL: " + $_.Exception.Message + " -> lanjut bootstrap dengan secret B64")
    exit 0
}
