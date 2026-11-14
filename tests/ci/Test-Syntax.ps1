# CI: parses every PowerShell file of the repository with the Windows PowerShell 5.1 parser, and checks that
# files with non-ASCII characters have a BOM (without one, 5.1 reads them as ANSI).
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$bad = 0
# Not -Include: together with -LiteralPath, 5.1 ignores it and returns every file
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File |
           Where-Object { @('.ps1', '.psd1') -contains $_.Extension -and $_.FullName -notmatch '\\\.git\\' })
foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($e in @($errors)) {
        Write-Host "::error file=$rel,line=$($e.Extent.StartLineNumber)::$($e.Message)"
        $bad++
    }
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom -and ($bytes | Where-Object { $_ -ge 0x80 } | Select-Object -First 1)) {
        Write-Host "::error file=$rel::znaki spoza ASCII bez BOM"
        $bad++
    }
}
Write-Host "Sprawdzono plików: $($files.Count), błędów: $bad."
if ($bad -gt 0) { exit 1 }
exit 0
