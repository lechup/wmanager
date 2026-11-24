# CI: runs in the session of each signed-in person, once per person: writes who it ran as.
# wmanager-run-as: user
$file = "C:\wm-ci\user-$env:USERNAME.txt"
New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
Set-Content -LiteralPath $file -Value "$(whoami)|$env:WMANAGER_GROUP|$([bool]$env:WMANAGER_GROUP_DIR)"
Write-Output "ran as $(whoami)"
exit 0
