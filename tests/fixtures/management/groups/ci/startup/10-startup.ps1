# CI: a startup script. Writes its group, the computer and the secret it names to a file, and prints the secret,
# which the log must show as ***.
# wmanager-secrets: CiShare
$ErrorActionPreference = 'Stop'
$file = 'C:\wm-ci\startup.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
[IO.File]::WriteAllText($file, ('{0}|{1}|{2}' -f $env:WMANAGER_GROUP, $env:WMANAGER_COMPUTER, $env:WMANAGER_SECRET_CISHARE))
Write-Output "startup secret: $env:WMANAGER_SECRET_CISHARE"
exit 0
