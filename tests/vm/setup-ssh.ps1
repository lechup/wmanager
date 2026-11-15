# wmanager test VM: run once at the first sign-in (FirstLogonCommands in autounattend.xml), from the setup CD.
# Installs the OpenSSH server (the MSI on the CD, or the Windows capability), allows the key of tests/vm/vm.sh
# for administrators, makes PowerShell the SSH shell and keeps the VM from sleeping.
$ErrorActionPreference = 'Stop'
Start-Transcript -LiteralPath 'C:\Windows\Temp\wm-setup-ssh.log' -Append | Out-Null
try {
    $msi = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'OpenSSH-Win64*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($msi) {
        $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$($msi.FullName)`"", '/qn', '/norestart' -Wait -PassThru
        Write-Output "msiexec: $($p.ExitCode)"
    } else {
        # Windows Update may not be ready right after setup; try a few times
        for ($i = 1; $i -le 5; $i++) {
            try { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null; break }
            catch { Write-Output "Add-WindowsCapability, próba ${i}: $($_.Exception.Message)"; Start-Sleep -Seconds 60 }
        }
    }

    $dir = Join-Path $env:ProgramData 'ssh'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $keys = Join-Path $dir 'administrators_authorized_keys'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'authorized_keys') -Destination $keys -Force
    & icacls.exe $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null

    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -PropertyType String -Force `
        -Value (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') | Out-Null

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd
    if (-not (Get-NetFirewallRule -Name 'wm-test-sshd' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'wm-test-sshd' -DisplayName 'OpenSSH (wmanager test VM)' -Direction Inbound `
            -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
    }

    powercfg.exe /change standby-timeout-ac 0
    powercfg.exe /change monitor-timeout-ac 0

    # OOBE of some builds (26300) replaces the name from autounattend.xml; the new one applies after a restart
    $nameFile = Join-Path $PSScriptRoot 'computer-name.txt'
    if (Test-Path -LiteralPath $nameFile) {
        $name = (Get-Content -LiteralPath $nameFile -TotalCount 1).Trim()
        if ($name -and $env:COMPUTERNAME -ne $name) {
            Rename-Computer -NewName $name -Force -WarningAction SilentlyContinue
            Write-Output "Nazwa komputera: $env:COMPUTERNAME -> $name (po restarcie)"
        }
    }
    Write-Output 'SSH gotowe.'
} catch {
    Write-Output "Błąd: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
