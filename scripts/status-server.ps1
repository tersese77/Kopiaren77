# status-server.ps1 — server HTTP kecil di runner, buat debug live lewat tailnet
#
# Kenapa: GitHub cuma menerbitkan log job SETELAH job selesai. Kalau bootstrap
# nyangkut, kita buta total. Server ini menyajikan status.txt (dan tail log)
# lewat port 8080 di tailnet, jadi bisa dicek kapan saja dari mesin lain:
#   curl http://<tailnet-ip-runner>:8080/         -> status.txt
#   curl http://<tailnet-ip-runner>:8080/log      -> tail log installer
#   curl http://<tailnet-ip-runner>:8080/health   -> ok
#
# Aman: cuma jalan di tailnet (port 8080 tidak diekspos ke internet), dan
# yang disajikan cuma file status/log, bukan isi .env.

param(
    [int]$Port = 8080,
    [string]$StatusFile = "$env:USERPROFILE\status.txt",
    [int]$Minutes = 400
)

$ErrorActionPreference = 'Continue'
$logDir = "$env:USERPROFILE\hermes-install"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

try {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:$Port/")
    $listener.Start()
} catch {
    # fallback: coba prefix localhost kalau "+" ditolak ACL
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Start()
    } catch {
        "[$(Get-Date -Format s)] status-server gagal start: $($_.Exception.Message)" |
            Out-File "$env:USERPROFILE\status-server-error.txt" -Encoding UTF8
        exit 1
    }
}

$deadline = (Get-Date).AddMinutes($Minutes)
while ((Get-Date) -lt $deadline) {
    try {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        $body = ''
        switch -Regex ($path) {
            '^/(health)?$' {
                $body = "ok $env:COMPUTERNAME $(Get-Date -Format s)`n"
                if (Test-Path $StatusFile) { $body += (Get-Content $StatusFile -Raw) }
            }
            '^/log' {
                $cand = @(Get-ChildItem "$logDir\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                if ($cand.Count -gt 0) { $body = (Get-Content $cand[0].FullName -Tail 80 | Out-String) }
                else { $body = 'belum ada log installer' }
            }
            '^/files' {
                $body = (Get-ChildItem "$env:USERPROFILE" -Force | Select-Object Name, Length, LastWriteTime | Out-String)
            }
            default {
                $body = if (Test-Path $StatusFile) { Get-Content $StatusFile -Raw } else { 'status.txt belum ada' }
            }
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.ContentType = 'text/plain; charset=utf-8'
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
    } catch {
        Start-Sleep -Seconds 1
    }
}
