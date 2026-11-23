# Tests

On Windows with Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester .\tests
```

The integration tests (`tests\Managed.Integration.Tests.ps1`) change the computer (trusted root store,
`C:\ProgramData\wmanager`, scheduled tasks), so they are skipped unless `WM_CI_SOURCES` is set; they run in CI.

**CI** (`.github/workflows/tests.yml`, every push and pull request, free on a public repository):

1. Linux: `bash -n` and shellcheck of the shell scripts; `tests/ci/build-sources.sh` builds test management sources
   from `examples/management` and `tests/fixtures/management` and signs them with `tools/publish.sh` and a throwaway key
   (timestamped by DigiCert or Sectigo; without a server that answers it signs without one and warns, `WM_TSA=none`
   doesn't ask one), and one more with a certificate that expired yesterday, timestamped by a test server while it
   was valid; `tools/new-signing-cert.sh` makes a key with a passphrase and a certificate valid for 20 years, and
   `publish.sh` signs with that key (a wrong passphrase signs nothing).
2. Windows Server 2025, Windows PowerShell 5.1: every `.ps1`/`.psd1` parsed (and checked for a BOM), the Pester tests,
   then the integration tests: Windows accepts the osslsigncode signature and its timestamp, keeps a timestamped
   signature of an expired certificate valid and rejects one without a timestamp, rejects an older manifest, a
   manifest of another source, a changed file and a changed manifest; a script runs once per content and a failing one
   every time;
   jobs run when due, their JSON lines reach the Loki batch with the `task` label; the example system report runs;
   the hourly task is registered; the wizard accepts the manifest signed with the source certificate and names
   another signer; a key change: the next certificate is trusted, forgotten when the source stops naming it, and
   becomes the computer's own when the source comes signed with it, while a source signed with a key the computer was
   never told about is rejected.
3. Linux, Docker: the Grafana dashboard and the alert rules against a real Loki and Grafana.
4. Linux, PowerShell 7: the tests of the configuration wizard (`init.ps1` also runs there), the languages,
   `tools/groups.ps1` and `tools/wm.ps1` (a new company signed with osslsigncode, when the runner's version can sign
   PowerShell files).

CI runs on Windows Server, not Windows 11 Home/Pro, so it doesn't replace the checks below.

Before rolling out to computers: Windows 11 Home and Pro virtual machines (with a snapshot), two consecutive runs
(the second run must not report errors), a manual run of the task, a missed schedule, the restart notification,
then one pilot computer for a week.

With a management source, also check on the virtual machine that `Get-AuthenticodeSignature` reports `Valid` for a
manifest signed by `publish.sh` (the signature is made with osslsigncode on Linux), that a changed file and an older
manifest are rejected, and that a script runs once, not again in the next run, and again after it changes; that
`wmanager-Jobs` repeats every hour and the daily report reaches Loki.

## Test virtual machines

`tests/vm/vm.sh` (Linux, KVM/QEMU) sets up Windows 11 Pro and Home virtual machines from the official Polish ISO
(microsoft.com/software-download/windows11), without a product key: unattended installation with TPM 2.0
(swtpm) and Secure Boot (OVMF), a local administrator `tester` signed in automatically, and an OpenSSH server for
commands from the terminal. The machines live in `~/vm/wmanager`, outside the repository.

```bash
sudo apt install -y qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools xorriso
sudo usermod -aG kvm $USER
tests/vm/vm.sh create pro ~/Downloads/Win11_pl.iso    # 30-60 min; done when: tests/vm/vm.sh ssh pro hostname
tests/vm/vm.sh installed pro                          # boot from the disk only from now on
tests/vm/vm.sh stop pro && tests/vm/vm.sh snapshot pro clean
tests/vm/vm.sh start pro                              # or with less memory: tests/vm/vm.sh start pro 4096
tests/vm/vm.sh deploy pro                             # working tree + example config -> C:\wmanager
tests/vm/vm.sh run pro Provision.ps1 -ComputerName WM-TEST-PRO
tests/vm/vm.sh stop pro && tests/vm/vm.sh revert pro clean
```

`deploy` copies the repository as it is on disk (uncommitted changes included) and `provision.config.example.psd1`,
or the configuration given as the second parameter (with the `.cer` files next to it).

A machine gets 6144 MB by default: give another amount as the last parameter of `start` or `create` (e.g.
`tests/vm/vm.sh start pro 4096`) or in `WM_VM_MEMORY`; at least 4096, which Windows 11 needs (provisioning works there
too, slower). `start` refuses when the host has less memory available than that plus 1 GB for itself, so a machine
doesn't push the host into swapping or other programs out (`WM_VM_MEMORY_CHECK=0` starts it anyway); two machines at
once rarely fit. `vm.sh stop` shuts Windows down fully over SSH: the power button only
hibernates the kernel while Fast Startup is on (the Windows default), so a new computer name or a pending update would
wait for a restart. Over SSH there is no console, so provisioning takes the default answers (as in a scheduled task).
