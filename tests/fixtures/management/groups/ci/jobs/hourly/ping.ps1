# CI: an hourly job printing one JSON line.
[pscustomobject]@{ kind = 'ping'; group = $env:WMANAGER_GROUP; computer = $env:WMANAGER_COMPUTER; job = $env:WMANAGER_JOB } |
    ConvertTo-Json -Compress
exit 0
