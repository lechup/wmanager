# CI: always fails, so it must run again every time.
$file = 'C:\wm-ci\fail.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
Add-Content -LiteralPath $file -Value 'run'
exit 5
