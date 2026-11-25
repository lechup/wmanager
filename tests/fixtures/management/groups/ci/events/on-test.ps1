# CI: an event script for an event of the Application log, which the test writes (Write-EventLog). Appends its group,
# the event as its line writes it, the event's log and record number and the secret it names to a file, and prints
# the secret, which the log must show as ***. No gap, so each test event runs it.
# wmanager-event: Application 4242 wmanager-ci
# wmanager-event-gap: 0
# wmanager-secrets: CiShare
$ErrorActionPreference = 'Stop'
$file = 'C:\wm-ci\event.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
Add-Content -LiteralPath $file -Value ('{0}|{1}|{2}|{3}|{4}' -f $env:WMANAGER_GROUP, $env:WMANAGER_EVENT, $env:WMANAGER_EVENT_LOG,
    $env:WMANAGER_EVENT_RECORD, $env:WMANAGER_SECRET_CISHARE)
Write-Output "event secret: $env:WMANAGER_SECRET_CISHARE"
exit 0
