#!/usr/bin/env bash
# wmanager: Windows 11 test virtual machines on KVM/QEMU, driven from the terminal.
#
# Two machines: "pro" (Windows 11 Pro) and "home" (Windows 11 Home), Polish, from the official multi-edition ISO
# without a product key (not activated). TPM 2.0 by swtpm, Secure Boot by OVMF. Run one at a time (6 GB RAM each).
#
#   tests/vm/vm.sh create <pro|home> <windows11.iso>   new disk, unattended installation (30-60 min)
#   tests/vm/vm.sh installed <vm>                      after the installation: boot from the disk only
#   tests/vm/vm.sh start <vm>                          start in the background
#   tests/vm/vm.sh stop <vm>                           full Windows shutdown (not Fast Startup), then stop
#   tests/vm/vm.sh status                              which machines run
#   tests/vm/vm.sh ssh <vm> [command]                  PowerShell over SSH as "tester" (administrator)
#   tests/vm/vm.sh copy <vm> <local-path> <win-path>   copy files into the machine (scp -r)
#   tests/vm/vm.sh deploy <vm> [config.psd1]           working tree of the repo + configuration -> C:\wmanager
#   tests/vm/vm.sh run <vm> <script.ps1> [params]      run a script from C:\wmanager, e.g. Provision.ps1 -ComputerName X
#   tests/vm/vm.sh screenshot <vm> <file.png>          what the screen shows now
#   tests/vm/vm.sh snapshot <vm> <name>                save the state of a stopped machine (disk, UEFI, TPM)
#   tests/vm/vm.sh revert <vm> <name>                  go back to a saved state (machine stopped)
#   tests/vm/vm.sh snapshots <vm>                      list saved states
#
# Machines live in $WM_VM_DIR (default ~/vm/wmanager), outside the repository. VNC for a look at the screen:
# 127.0.0.1:5901 (pro), 127.0.0.1:5902 (home). Needs: qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools xorriso,
# and membership in the kvm group (sudo usermod -aG kvm $USER).
set -euo pipefail

die() { echo "BŁĄD: $*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
base=${WM_VM_DIR:-$HOME/vm/wmanager}
self=$here/$(basename "$0")
repo=$(cd "$here/../.." && pwd)
args=("$@")

vm_conf() {
    case $1 in
        # Microsoft's generic installation keys: they choose the edition and don't activate Windows
        pro)  key=VK7JG-NPHTM-C97JM-9MPGT-3V66T; computer=WM-TEST-PRO;  ssh_port=2222; vnc=1 ;;
        home) key=YTMG3-N6DKC-DKB77-7M9GH-8HVX7; computer=WM-TEST-HOME; ssh_port=2223; vnc=2 ;;
        *) die "nieznana maszyna '$1' (pro albo home)" ;;
    esac
    dir=$base/$1
}

need() { for c in "$@"; do command -v "$c" >/dev/null || die "brak $c (sudo apt install -y qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools xorriso)"; done; }

# /dev/kvm: the kvm group, or the ACL logind gives to the user at the screen (gone while the screen is locked).
# A member of the kvm group who hasn't signed in again since joining gets the group through sg.
need_kvm() {
    [[ -r /dev/kvm && -w /dev/kvm ]] && return
    if [[ -z ${WM_VM_SG:-} ]] && getent group kvm | cut -d: -f4 | tr , '\n' | grep -qx "$USER"; then
        export WM_VM_SG=1
        exec sg kvm -c "$(printf '%q ' "$self" "${args[@]}")"
    fi
    die "brak dostępu do /dev/kvm: sudo usermod -aG kvm \$USER (potem ponowne zalogowanie albo uruchamianie przez sg kvm)"
}

ovmf_file() {
    for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done
    die "brak plików OVMF ($*); zainstaluj pakiet ovmf"
}

running() { [[ -f $dir/qemu.pid ]] && kill -0 "$(cat "$dir/qemu.pid")" 2>/dev/null; }

# Sends QMP commands (JSON lines) to the machine and prints the answers
qmp() {
    python3 - "$dir/qmp.sock" "$@" <<'PY'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile('rw')
f.readline()                                   # greeting
def call(cmd):
    f.write(json.dumps(cmd) + '\n'); f.flush()
    while True:
        r = json.loads(f.readline())
        if 'event' not in r:
            return r
call({'execute': 'qmp_capabilities'})
for a in sys.argv[2:]:
    if a.startswith('sleep:'):
        time.sleep(float(a[6:])); continue
    print(json.dumps(call(json.loads(a))))
PY
}

ssh_opts=()
set_ssh_opts() {
    ssh_opts=(-i "$base/ssh/id_ed25519" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
              -o "UserKnownHostsFile=$dir/known_hosts" -o ConnectTimeout=10)
}

cmd_create() {
    local name=$1 iso=$2
    need qemu-system-x86_64 qemu-img swtpm xorriso ssh-keygen python3 curl
    need_kvm   # before anything is created: it may run the script again through sg
    vm_conf "$name"
    [[ -f $iso ]] || die "brak pliku ISO $iso"
    [[ -e $dir/disk.qcow2 ]] && die "maszyna $name już istnieje ($dir); usuń ten folder, żeby zacząć od nowa"
    mkdir -p "$dir/tpm" "$dir/cd" "$base/ssh"
    chmod 700 "$base" "$base/ssh"

    [[ -f $base/ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C "wmanager-test-vm" -f "$base/ssh/id_ed25519"
    local password
    password=$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')   # letters, digits, - and _
    printf '%s\n' "$password" > "$dir/password.txt"
    chmod 600 "$dir/password.txt"

    sed -e "s/@PRODUCT_KEY@/$key/" -e "s/@COMPUTER_NAME@/$computer/" -e "s/@PASSWORD@/$password/g" \
        "$here/autounattend.xml.in" > "$dir/cd/autounattend.xml"
    cp "$here/setup-ssh.ps1" "$dir/cd/"
    cp "$base/ssh/id_ed25519.pub" "$dir/cd/authorized_keys"
    # OOBE of some builds (26300) renames the computer after specialize; setup-ssh.ps1 sets it back
    printf '%s\r\n' "$computer" > "$dir/cd/computer-name.txt"
    # The OpenSSH MSI makes SSH independent of Windows Update right after installation (best effort)
    local msi_url
    msi_url=$(curl -fsSL https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest 2>/dev/null |
              python3 -c 'import json,sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].startswith("OpenSSH-Win64") and a["name"].endswith(".msi")))' 2>/dev/null || true)
    if [[ -n $msi_url ]] && curl -fsSL -o "$dir/cd/${msi_url##*/}" "$msi_url"; then
        echo "OpenSSH: ${msi_url##*/}"
    else
        echo "UWAGA: nie pobrałem OpenSSH MSI; Windows zainstaluje SSH z Windows Update" >&2
    fi
    xorriso -as mkisofs -quiet -V UNATTEND -J -r -o "$dir/unattend.iso" "$dir/cd"

    qemu-img create -q -f qcow2 "$dir/disk.qcow2" 80G
    cp "$(ovmf_file /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd)" "$dir/OVMF_VARS.fd"
    realpath "$iso" > "$dir/install.iso"
    echo "Maszyna $name: $dir. Instaluję Windows ($computer)..."
    cmd_start "$name"
    echo "Instalacja trwa (45-90 min). Postęp: tests/vm/vm.sh screenshot $name ekran.png; gotowe, gdy działa: tests/vm/vm.sh ssh $name hostname"
}

cmd_start() {
    vm_conf "$1"
    need qemu-system-x86_64 swtpm
    need_kvm
    [[ -f $dir/disk.qcow2 ]] || die "maszyna $1 nie istnieje (tests/vm/vm.sh create $1 <iso>)"
    running && { echo "Maszyna $1 już działa."; return; }
    rm -f "$dir/swtpm.sock" "$dir/qmp.sock"
    swtpm socket --tpm2 --tpmstate dir="$dir/tpm" --ctrl type=unixio,path="$dir/swtpm.sock" \
        --daemon --pid file="$dir/swtpm.pid" --log file="$dir/swtpm.log"
    for _ in $(seq 1 50); do [[ -S $dir/swtpm.sock ]] && break; sleep 0.1; done

    local cds=()
    if [[ -f $dir/install.iso ]]; then
        cds=(-drive "file=$(cat "$dir/install.iso"),media=cdrom,if=none,id=cd0,readonly=on" -device ide-cd,drive=cd0,bus=ahci.1,bootindex=2
             -drive "file=$dir/unattend.iso,media=cdrom,if=none,id=cd1,readonly=on" -device ide-cd,drive=cd1,bus=ahci.2)
    fi
    qemu-system-x86_64 \
        -name "wm-test-$1" -enable-kvm -machine q35,smm=on \
        -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time -smp 4 -m 6144 \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(ovmf_file /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd)" \
        -drive "if=pflash,format=raw,unit=1,file=$dir/OVMF_VARS.fd" \
        -chardev socket,id=chrtpm,path="$dir/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
        -device ahci,id=ahci \
        -drive "file=$dir/disk.qcow2,if=none,id=disk0,format=qcow2,discard=unmap" -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
        "${cds[@]}" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" -device e1000e,netdev=net0 \
        -device qemu-xhci -device usb-tablet -vga std \
        -display none -vnc "127.0.0.1:$vnc" \
        -qmp "unix:$dir/qmp.sock,server=on,wait=off" \
        -rtc base=localtime \
        -daemonize -pidfile "$dir/qemu.pid"
    for _ in $(seq 1 50); do [[ -S $dir/qmp.sock ]] && break; sleep 0.1; done
    if [[ -f $dir/install.iso ]]; then
        # The Windows DVD asks to "press any key" to boot from it (only while the disk is empty)
        local enter='{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}' presses=()
        for _ in $(seq 1 40); do presses+=("$enter" sleep:0.5); done
        qmp "${presses[@]}" >/dev/null
    fi
    echo "Maszyna $1 działa (SSH 127.0.0.1:$ssh_port, VNC 127.0.0.1:$((5900 + vnc)))."
}

cmd_stop() {
    vm_conf "$1"
    if running; then
        # A full shutdown: the power button only hibernates the kernel when Fast Startup is on (the Windows
        # default), so a pending computer name or update would wait, and a saved state would hold a hibernated system
        set_ssh_opts
        ssh "${ssh_opts[@]}" -o BatchMode=yes -o ConnectTimeout=5 -p "$ssh_port" tester@127.0.0.1 'shutdown.exe /s /t 0' \
            </dev/null >/dev/null 2>&1 || qmp '{"execute":"system_powerdown"}' >/dev/null
        for _ in $(seq 1 120); do running || break; sleep 1; done
        if running; then echo "Windows nie wyłączył się w 2 minuty; zatrzymuję maszynę." >&2; qmp '{"execute":"quit"}' >/dev/null || true; sleep 2; fi
    fi
    [[ -f $dir/swtpm.pid ]] && kill "$(cat "$dir/swtpm.pid")" 2>/dev/null || true
    rm -f "$dir/qemu.pid" "$dir/swtpm.pid"
    echo "Maszyna $1 zatrzymana."
}

cmd_status() {
    for n in pro home; do
        vm_conf "$n"
        if [[ ! -f $dir/disk.qcow2 ]]; then echo "$n: brak"
        elif running; then echo "$n: działa (SSH $ssh_port)"
        else echo "$n: zatrzymana"; fi
    done
}

cmd_ssh() {
    vm_conf "$1"; shift
    set_ssh_opts
    ssh "${ssh_opts[@]}" -p "$ssh_port" tester@127.0.0.1 "$@"
}

cmd_copy() {
    vm_conf "$1"
    set_ssh_opts
    scp -q -r "${ssh_opts[@]}" -P "$ssh_port" "$2" "tester@127.0.0.1:$3"
}

# The working tree of the repository (tracked and new files, uncommitted changes included, without tests/) and a
# configuration go to C:\wmanager; the folder is replaced. The configuration defaults to the example (no tokens);
# .cer files next to the given configuration go along (the management source certificate).
cmd_deploy() {
    vm_conf "$1"
    local config=${2:-$repo/provision.config.example.psd1} stage f cer
    [[ -f $config ]] || die "brak pliku konfiguracji $config"
    stage=$(mktemp -d)
    mkdir "$stage/wmanager"
    while IFS= read -r -d '' f; do
        [[ $f == tests/* || ! -f $repo/$f ]] && continue
        mkdir -p "$stage/wmanager/$(dirname "$f")"
        cp "$repo/$f" "$stage/wmanager/$f"
    done < <(git -C "$repo" ls-files -z --cached --others --exclude-standard)
    cp "$config" "$stage/wmanager/provision.config.psd1"
    for cer in "$(dirname "$config")"/*.cer; do [[ -f $cer ]] && cp "$cer" "$stage/wmanager/"; done
    set_ssh_opts
    ssh "${ssh_opts[@]}" -p "$ssh_port" tester@127.0.0.1 \
        'if (Test-Path C:\wmanager) { Remove-Item C:\wmanager -Recurse -Force }' </dev/null
    scp -q -r "${ssh_opts[@]}" -P "$ssh_port" "$stage/wmanager" "tester@127.0.0.1:C:/"
    rm -rf "$stage"
    echo "Maszyna $1: wmanager w C:\wmanager (konfiguracja: $config)."
}

# Runs a wmanager script from C:\wmanager as administrator over SSH (no console: default answers, as in a scheduled
# task); the output comes back converted from the Windows console code page; the exit code is the script's.
cmd_run() {
    vm_conf "$1"; shift
    local script=$1 a ps; shift
    [[ $script =~ ^[A-Za-z0-9._-]+\.ps1$ ]] || die "skrypt: nazwa pliku .ps1 z C:\wmanager (np. Provision.ps1)"
    ps="powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\wmanager\\$script"
    for a in "$@"; do ps+=" '${a//\'/\'\'}'"; done
    ps+='; exit $LASTEXITCODE'
    set_ssh_opts
    ssh "${ssh_opts[@]}" -p "$ssh_port" tester@127.0.0.1 "$ps" </dev/null 2>&1 | iconv -f CP852 -t UTF-8 | tr -d '\r'
    return "${PIPESTATUS[0]}"
}

cmd_screenshot() {
    vm_conf "$1"
    running || die "maszyna $1 nie działa"
    local out
    out=$(realpath -m "$2")
    qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$out\",\"format\":\"png\"}}" >/dev/null
    echo "$out"
}

cmd_snapshot() {
    vm_conf "$1"
    running && die "zatrzymaj maszynę przed zapisaniem stanu (tests/vm/vm.sh stop $1)"
    [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || die "nazwa stanu: litery, cyfry, . - _"
    qemu-img snapshot -c "$2" "$dir/disk.qcow2"
    mkdir -p "$dir/snapshots/$2"
    cp "$dir/OVMF_VARS.fd" "$dir/snapshots/$2/"
    tar -C "$dir" -cf "$dir/snapshots/$2/tpm.tar" tpm
    echo "Zapisano stan $2 maszyny $1."
}

cmd_revert() {
    vm_conf "$1"
    running && die "zatrzymaj maszynę przed powrotem do stanu (tests/vm/vm.sh stop $1)"
    [[ -d $dir/snapshots/$2 ]] || die "brak stanu $2 (tests/vm/vm.sh snapshots $1)"
    qemu-img snapshot -a "$2" "$dir/disk.qcow2"
    cp "$dir/snapshots/$2/OVMF_VARS.fd" "$dir/"
    rm -rf "$dir/tpm"
    tar -C "$dir" -xf "$dir/snapshots/$2/tpm.tar"
    echo "Maszyna $1 wróciła do stanu $2."
}

cmd_snapshots() {
    vm_conf "$1"
    qemu-img snapshot -l "$dir/disk.qcow2"
}

# After the installation: boot from the disk only
cmd_installed() {
    vm_conf "$1"
    rm -f "$dir/install.iso"
    echo "Maszyna $1: płyty instalacyjne odłączone (od następnego startu)."
}

[[ $# -ge 1 ]] || { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
cmd=$1; shift
case $cmd in
    create)     [[ $# -eq 2 ]] || die "użycie: $0 create <pro|home> <iso>"; cmd_create "$@" ;;
    start)      [[ $# -eq 1 ]] || die "użycie: $0 start <vm>"; cmd_start "$1" ;;
    stop)       [[ $# -eq 1 ]] || die "użycie: $0 stop <vm>"; cmd_stop "$1" ;;
    status)     cmd_status ;;
    ssh)        [[ $# -ge 1 ]] || die "użycie: $0 ssh <vm> [polecenie]"; cmd_ssh "$@" ;;
    copy)       [[ $# -eq 3 ]] || die "użycie: $0 copy <vm> <lokalnie> <ścieżka-w-windows>"; cmd_copy "$@" ;;
    deploy)     [[ $# -ge 1 && $# -le 2 ]] || die "użycie: $0 deploy <vm> [provision.config.psd1]"; cmd_deploy "$@" ;;
    run)        [[ $# -ge 2 ]] || die "użycie: $0 run <vm> <skrypt.ps1> [parametry]"; cmd_run "$@" ;;
    screenshot) [[ $# -eq 2 ]] || die "użycie: $0 screenshot <vm> <plik.png>"; cmd_screenshot "$@" ;;
    snapshot)   [[ $# -eq 2 ]] || die "użycie: $0 snapshot <vm> <nazwa>"; cmd_snapshot "$@" ;;
    revert)     [[ $# -eq 2 ]] || die "użycie: $0 revert <vm> <nazwa>"; cmd_revert "$@" ;;
    snapshots)  [[ $# -eq 1 ]] || die "użycie: $0 snapshots <vm>"; cmd_snapshots "$1" ;;
    installed)  [[ $# -eq 1 ]] || die "użycie: $0 installed <vm>"; cmd_installed "$1" ;;
    *) die "nieznane polecenie '$cmd'" ;;
esac
