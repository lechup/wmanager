# Trials 2-4 of stage 0 (docs/trials.md), on a test virtual machine only: it trusts a self-signed certificate
# machine-wide and changes Windows' signature checking. Run as administrator in C:\trial, with wmtrial.exe there:
#   tests/vm/vm.sh copy pro wmtrial.exe 'C:\trial\wmtrial.exe'
#   tests/vm/vm.sh copy pro trials/vm/stage0.ps1 'C:\trial\stage0.ps1'
#   tests/vm/vm.sh ssh pro 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\trial\stage0.ps1'
$ErrorActionPreference = 'Stop'
Set-Location C:\trial

# Each check runs in a new process, so a changed EnableCertPaddingCheck is surely read again.
function Show-Signature([string[]]$names) {
    foreach ($n in $names) {
        $r = powershell -NoProfile -Command "`$s = Get-AuthenticodeSignature 'C:\trial\$n.exe'; '{0}|{1}' -f `$s.Status, `$s.StatusMessage"
        $status, $message = "$r" -split '\|', 2
        '  {0,-10} {1,-14} {2}' -f $n, $status, $message
    }
}

'== Windows'
$os = Get-CimInstance Win32_OperatingSystem
'  {0} {1} (build {2})' -f $os.Caption, $os.Version, $os.BuildNumber

'== Signing (a self-signed code signing certificate, trusted on this machine only)'
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=wmanager trial' `
    -CertStoreLocation Cert:\LocalMachine\My -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256
Export-Certificate -Cert $cert -FilePath trial.cer | Out-Null
# certutil: Import-Certificate is refused (E_ACCESSDENIED) for the Root store on Windows 11 build 26300, also as
# SYSTEM, while certutil adds it
certutil -addstore -f Root trial.cer | Out-Null
certutil -addstore -f TrustedPublisher trial.cer | Out-Null
Copy-Item wmtrial.exe unsigned.exe -Force
Copy-Item wmtrial.exe signed.exe -Force
Set-AuthenticodeSignature -FilePath signed.exe -Certificate $cert -HashAlgorithm SHA256 | Out-Null
'  ' + (.\unsigned.exe settag signed.exe tagged.exe '{"server":"https://wm.example.com","token":"trial"}')
'  ' + (.\unsigned.exe append signed.exe appended.exe 'old style tag')
.\unsigned.exe settag tagged.exe retagged.exe ('chain ' * 5000) | Out-Null

$keys = 'HKLM:\Software\Microsoft\Cryptography\Wintrust\Config',
        'HKLM:\Software\Wow6432Node\Microsoft\Cryptography\Wintrust\Config'
foreach ($k in $keys) { if (Test-Path $k) { Remove-ItemProperty -Path $k -Name EnableCertPaddingCheck -ErrorAction SilentlyContinue } }
'== Trial 2: signatures, EnableCertPaddingCheck off (the Windows default)'
Show-Signature unsigned, signed, tagged, retagged, appended
foreach ($k in $keys) {
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name EnableCertPaddingCheck -Value '1' -Type String
}
'== Trial 2: signatures, EnableCertPaddingCheck on'
Show-Signature unsigned, signed, tagged, retagged, appended
'== Trial 2: the tagged exe reads its own tag'
'  tagged.exe:   ' + (.\tagged.exe tag)
'  retagged.exe: ' + ((.\retagged.exe tag).Length) + ' characters'
'  signed.exe:   ' + (.\signed.exe tag)

'== Trial 4: Defender'
$st = Get-MpComputerStatus
'  real-time protection {0}, signatures {1}, engine {2}' -f $st.RealTimeProtectionEnabled, $st.AntivirusSignatureVersion, $st.AMEngineVersion
'  cloud protection (MAPS) {0}, sample submission {1}' -f (Get-MpPreference).MAPSReporting, (Get-MpPreference).SubmitSamplesConsent
$mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
foreach ($n in 'unsigned', 'signed', 'tagged') {
    $out = & $mp -Scan -ScanType 3 -File "C:\trial\$n.exe" -DisableRemediation 2>&1 | Out-String
    $verdict = if ($out -match 'found no threats') { 'no threats' } else { ($out.Trim() -split "`r?`n")[-1] }
    '  {0,-10} {1}' -f $n, $verdict
}
$det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.Resources -match 'C:\\trial' })
'  detections in C:\trial: {0}' -f $det.Count
$det | ForEach-Object { '    {0} {1}' -f $_.ThreatID, ($_.Resources -join ', ') }

'== Trial 3: the TPM'
$tpm = Get-Tpm
'  present {0}, ready {1}, maker {2} {3}' -f $tpm.TpmPresent, $tpm.TpmReady, $tpm.ManufacturerIdTxt, $tpm.ManufacturerVersion
'-- as administrator (this SSH session)'
.\unsigned.exe tpm 2>&1 | ForEach-Object { "  $_" }
'-- as SYSTEM (a scheduled task), as the agent will run'
$task = 'wmanager-trial-tpm'
schtasks /create /tn $task /ru SYSTEM /sc once /st 23:59 /f /tr "cmd /c C:\trial\unsigned.exe tpm > C:\trial\tpm-system.txt 2>&1" | Out-Null
schtasks /run /tn $task | Out-Null
Start-Sleep 2
for ($i = 0; $i -lt 60 -and (Get-ScheduledTask -TaskName $task).State -eq 'Running'; $i++) { Start-Sleep 1 }
Get-Content tpm-system.txt | ForEach-Object { "  $_" }
schtasks /delete /tn $task /f | Out-Null
