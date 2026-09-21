# runner-backup.ps1 — backup state Hermes tiap host runner -> GitHub artifact (terenkripsi)
# Dipanggil di akhir run (langkah "Backup Hermes state") SEBELUM keep-alive mati.
# Enkripsi AES-256-CBC via openssl, kunci = secret BACKUP_KEY (host mana pun bisa restore).
# Restore: openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:<BACKUP_KEY> -in backup.tar.gz.enc | tar -xzf - -C $env:HERMES_HOME

$ErrorActionPreference = 'Continue'
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { 'C:\Users\clouduser\AppData\Local\hermes' }
$Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$Work  = Join-Path $env:TEMP 'hermes-backup'
$ArtifactName = "hermes-state-backup"

function Status([string]$msg) {
    $line = '[backup] ' + $msg
    Write-Host $line
    try { Add-Content -Path (Join-Path $env:USERPROFILE 'status.txt') -Value $line -Encoding UTF8 } catch { }
}

if (-not $env:BACKUP_KEY) {
    Status 'BACKUP_KEY kosong -> backup DILEWATI (set secret BACKUP_KEY dulu)'
    exit 0
}

try {
    if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
    New-Item -ItemType Directory -Path $Work -Force | Out-Null

    # 1. Kumpulkan state: config, .env, memories, skills, cron, auth, sessions index
    $stage = Join-Path $Work 'hermes-state'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($item in @('config.yaml', '.env', 'state.db', 'memories', 'skills', 'cron', 'auth.json', 'sessions')) {
        $src = Join-Path $HermesHome $item
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $stage $item) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # buang file besar/tidak perlu: transcript jsonl besar & cache venv
    Get-ChildItem (Join-Path $stage 'sessions') -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 5MB } | Remove-Item -Force -ErrorAction SilentlyContinue

    # 2. tar.gz
    $tarGz = Join-Path $Work 'hermes-state.tar.gz'
    & "$env:SystemRoot\system32\tar.exe" -czf $tarGz -C $Work 'hermes-state' 2>$null
    if (-not (Test-Path $tarGz)) { throw 'tar gagal' }
    $sizeMB = [math]::Round((Get-Item $tarGz).Length / 1MB, 1)
    Status ("state dikumpulkan: {0} MB" -f $sizeMB)

    # 3. Enkripsi AES-256 (openssl dari Git for Windows yang ada di runner)
    $enc = Join-Path $Work 'hermes-state.tar.gz.enc'
    $openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
    if (-not $openssl) { $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe' }
    if (-not (Test-Path $openssl)) { throw 'openssl tidak ditemukan' }
    $p = Start-Process -FilePath $openssl -ArgumentList @('enc','-aes-256-cbc','-pbkdf2','-salt',
        '-pass',"pass:$($env:BACKUP_KEY)",'-in',$tarGz,'-out',$enc) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -or -not (Test-Path $enc)) { throw "openssl enc exit=$($p.ExitCode)" }
    Status ('terenkripsi: ' + [math]::Round((Get-Item $enc).Length / 1MB, 1) + ' MB')

    # 4. Dua artefak: file terenkripsi + versi base64 untuk restore via API/artifact
    Copy-Item $enc (Join-Path $env:TEMP 'hermes-state.tar.gz.enc') -Force
    "hermes-state.tar.gz.enc" | Set-Content (Join-Path $env:TEMP 'hermes-backup-name.txt') -Encoding ASCII

    # 5. Salinan juga dikirim ke Telegram (hanya nama+ukuran+stamp, bukan isi)
    Status "backup siap diartifact: $ArtifactName (stamp $Stamp, $sizeMB MB)"

    # simpan ringkasan untuk langkah upload artifact
    @{ stamp = $Stamp; size_mb = $sizeMB; artifact = $ArtifactName } |
        ConvertTo-Json | Set-Content (Join-Path $env:TEMP 'hermes-backup-meta.json') -Encoding UTF8
    exit 0
} catch {
    Status ("BACKUP GAGAL: " + $_.Exception.Message)
    exit 1   # keep-alive jalan terus walau backup gagal (step ini if: success() di workflow)
}
