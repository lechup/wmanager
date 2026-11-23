# CI: names a secret and gets it from the configuration as an environment variable; it prints the value, on both
# streams, and the log must show *** instead.
# wmanager-secrets: CiShare
$ErrorActionPreference = 'Stop'
$file = 'C:\wm-ci\secret.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
[IO.File]::WriteAllText($file, [string]$env:WMANAGER_SECRET_CISHARE)
Write-Output "secret: $env:WMANAGER_SECRET_CISHARE"
[Console]::Error.WriteLine("on stderr too: $env:WMANAGER_SECRET_CISHARE")
exit 0
