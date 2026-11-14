# CI: appends a line on every run; the test expects one run per content.
$ErrorActionPreference = 'Stop'
$file = 'C:\wm-ci\marker.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
Add-Content -LiteralPath $file -Value "run $env:WMANAGER_GROUP"
Write-Output 'Znacznik zapisany.'
exit 0
