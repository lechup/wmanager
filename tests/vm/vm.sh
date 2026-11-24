#!/usr/bin/env bash
# wmanager: Windows 11 test virtual machines on KVM/QEMU, driven from the terminal.
#
# Two machines: "pro" (Windows 11 Pro) and "home" (Windows 11 Home), Polish, from the official multi-edition ISO
# without a product key (not activated). TPM 2.0 by swtpm, Secure Boot by OVMF.
#
#   tests/vm/vm.sh create <pro|home> <windows11.iso> [memory-MB]   new disk, unattended installation (30-60 min)
#   tests/vm/vm.sh installed <vm>                      after the installation: boot from the disk only
#   tests/vm/vm.sh start <vm> [memory-MB]              start in the background and wait until SSH answers (a boot
#                                                      that hangs is reset once; WM_VM_WAIT=0: don't wait)
#   tests/vm/vm.sh wait <vm>                           wait until SSH answers, the same way
#   tests/vm/vm.sh restart <vm>                        restart Windows and wait until the new one answers
#   tests/vm/vm.sh stop <vm>                           full Windows shutdown (not Fast Startup), then stop
#   tests/vm/vm.sh status                              which machines run
#   tests/vm/vm.sh ssh <vm> [command]                  PowerShell over SSH as "tester" (administrator)
#   tests/vm/vm.sh copy <vm> <local-path> <win-path>   copy files into the machine (scp -r)
#   tests/vm/vm.sh deploy <vm> [config.psd1]           working tree of the repo + configuration -> C:\wmanager
#   tests/vm/vm.sh run <vm> <script.ps1> [params]      run a script from C:\wmanager, e.g. Provision.ps1 -ComputerName X
#   tests/vm/vm.sh screenshot <vm> <file.png>          what the screen shows now
#   tests/vm/vm.sh snapshot <vm> <name>                save the state of a stopped machine (disk, UEFI, TPM)
#   tests/vm/vm.sh revert <vm> <name>                  go back to a saved state (machine stopped)
#   tests/vm/vm.sh forget <vm> <name>                  delete a saved state
#   tests/vm/vm.sh snapshots <vm>                      list saved states
#
# Memory of a machine: the [memory-MB] given, else $WM_VM_MEMORY, else 6144; at least 4096 (Windows 11 won't install
# with less; provisioning works there too, slower). A start is refused when the host has less memory available than
# that plus 1 GB for itself (two machines at once rarely fit); WM_VM_MEMORY_CHECK=0 skips that check.
#
# Machines live in $WM_VM_DIR (default ~/vm/wmanager), outside the repository. VNC for a look at the screen:
# 127.0.0.1:5901 (pro), 127.0.0.1:5902 (home). Needs: qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools xorriso,
# and membership in the kvm group (sudo usermod -aG kvm $USER).
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

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
        *) die "unknown machine '$1' (pro or home)" ;;
    esac
    dir=$base/$1
}

need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c not found (sudo apt install -y qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools xorriso)"; done; }

# /dev/kvm: the kvm group, or the ACL logind gives to the user at the screen (gone while the screen is locked).
# A member of the kvm group who hasn't signed in again since joining gets the group through sg.
need_kvm() {
    [[ -r /dev/kvm && -w /dev/kvm ]] && return
    if [[ -z ${WM_VM_SG:-} ]] && getent group kvm | cut -d: -f4 | tr , '\n' | grep -qx "$USER"; then
        export WM_VM_SG=1
        exec sg kvm -c "$(printf '%q ' "$self" "${args[@]}")"
    fi
    die "no access to /dev/kvm: sudo usermod -aG kvm \$USER (then sign in again, or run through sg kvm)"
}

ovmf_file() {
    for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done
    die "OVMF files not found ($*); install the ovmf package"
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

# Runs a command over SSH without waiting long: false when SSH doesn't answer within 5 s or the command doesn't end
# within 20 (a booting Windows may open the connection and never start the session). Options before ssh_opts: ssh
# takes the first value it gets.
ssh_answers() {
    set_ssh_opts
    timeout 20 ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_opts[@]}" -p "$ssh_port" tester@127.0.0.1 "$@" \
        </dev/null >/dev/null 2>&1
}

# The QMP command that saves the screen to a file (PPM, or the given format)
screendump_json() {
    local file
    file=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
    echo "{\"execute\":\"screendump\",\"arguments\":{\"filename\":$file${2:+,\"format\":\"$2\"}}}"
}

# The memory for a machine in MB (see the header), checked against what the host has available
vm_memory() {
    local mb=${1:-${WM_VM_MEMORY:-6144}} avail
    [[ $mb =~ ^[0-9]+$ ]] || die "memory: a number of megabytes, e.g. 4096 ('$mb')"
    (( mb >= 4096 )) || die "memory: at least 4096 MB, as Windows 11 needs ($mb)"
    if [[ ${WM_VM_MEMORY_CHECK:-1} != 0 && -r /proc/meminfo ]]; then
        avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
        if [[ -n $avail ]] && (( avail < mb + 1024 )); then
            die "the host has $avail MB available; this machine needs $mb MB and the host about 1024 more. Close programs (or stop the other machine), or give it less, e.g.: $0 start <vm> 4096 (at least 4096). WM_VM_MEMORY_CHECK=0 starts it anyway."
        fi
    fi
    echo "$mb"
}

cmd_create() {
    local name=$1 iso=$2 memory=${3:-}
    need qemu-system-x86_64 qemu-img swtpm xorriso ssh-keygen python3 curl
    need_kvm   # before anything is created: it may run the script again through sg
    vm_conf "$name"
    [[ -f $iso ]] || die "ISO file $iso not found"
    [[ -e $dir/disk.qcow2 ]] && die "machine $name already exists ($dir); delete that folder to start over"
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
        echo "WARNING: could not download the OpenSSH MSI; Windows will install SSH from Windows Update" >&2
    fi
    xorriso -as mkisofs -quiet -V UNATTEND -J -r -o "$dir/unattend.iso" "$dir/cd"

    qemu-img create -q -f qcow2 "$dir/disk.qcow2" 80G
    cp "$(ovmf_file /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd)" "$dir/OVMF_VARS.fd"
    realpath "$iso" > "$dir/install.iso"
    echo "Machine $name: $dir. Installing Windows ($computer)..."
    cmd_start "$name" "$memory"
    echo "Installing (45-90 min). Progress: tests/vm/vm.sh screenshot $name screen.png; done when this works: tests/vm/vm.sh ssh $name hostname"
}

cmd_start() {
    vm_conf "$1"
    need qemu-system-x86_64 swtpm
    need_kvm
    [[ -f $dir/disk.qcow2 ]] || die "machine $1 does not exist (tests/vm/vm.sh create $1 <iso>)"
    if running; then
        echo "Machine $1 is already running."
        if [[ ! -f $dir/install.iso && ${WM_VM_WAIT:-1} != 0 ]]; then wait_ready "$1"; fi
        return
    fi
    local memory
    memory=$(vm_memory "${2:-}")
    rm -f "$dir/swtpm.sock" "$dir/qmp.sock"
    swtpm socket --tpm2 --tpmstate dir="$dir/tpm" --ctrl type=unixio,path="$dir/swtpm.sock" \
        --daemon --pid file="$dir/swtpm.pid" --log file="$dir/swtpm.log"
    for _ in $(seq 1 50); do [[ -S $dir/swtpm.sock ]] && break; sleep 0.1; done

    # qemu option values: a comma inside a path is written twice
    local d=${dir//,/,,} iso cds=() code
    code=$(ovmf_file /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd)
    if [[ -f $dir/install.iso ]]; then
        iso=$(cat "$dir/install.iso")
        cds=(-drive "file=${iso//,/,,},media=cdrom,if=none,id=cd0,readonly=on" -device ide-cd,drive=cd0,bus=ahci.1,bootindex=2
             -drive "file=$d/unattend.iso,media=cdrom,if=none,id=cd1,readonly=on" -device ide-cd,drive=cd1,bus=ahci.2)
    fi
    if ! qemu-system-x86_64 \
        -name "wm-test-$1" -enable-kvm -machine q35,smm=on \
        -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time -smp 4 -m "$memory" \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=${code//,/,,}" \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -chardev socket,id=chrtpm,path="$d/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
        -device ahci,id=ahci \
        -drive "file=$d/disk.qcow2,if=none,id=disk0,format=qcow2,discard=unmap" -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
        "${cds[@]}" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" -device e1000e,netdev=net0 \
        -device qemu-xhci -device usb-tablet -vga std \
        -display none -vnc "127.0.0.1:$vnc" \
        -qmp "unix:$d/qmp.sock,server=on,wait=off" \
        -rtc base=localtime \
        -daemonize -pidfile "$dir/qemu.pid"
    then
        # swtpm would keep the TPM state locked and the next start would fail on it
        stop_swtpm
        die "qemu did not start (message above)"
    fi
    for _ in $(seq 1 50); do [[ -S $dir/qmp.sock ]] && break; sleep 0.1; done
    if [[ -f $dir/install.iso ]]; then
        # The Windows DVD asks to "press any key" to boot from it (only while the disk is empty)
        local enter='{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}' presses=()
        for _ in $(seq 1 40); do presses+=("$enter" sleep:0.5); done
        qmp "${presses[@]}" >/dev/null
    fi
    echo "Machine $1 is running with $memory MB (SSH 127.0.0.1:$ssh_port, VNC 127.0.0.1:$((5900 + vnc)))."
    # Not while Windows installs: SSH comes only at its end
    if [[ ! -f $dir/install.iso && ${WM_VM_WAIT:-1} != 0 ]]; then wait_ready "$1"; fi
}

# Waits until SSH answers. On a busy host a boot sometimes hangs (the spinner stops, SSH never comes, and only a
# reset helps): no SSH and the same screen for 5 minutes is taken for that, and the machine is reset once (two cut-off
# boots in a row would send Windows into Automatic Repair). Each look takes two frames a second apart, so a turning
# spinner always counts as alive; a boot that installs updates changes its percentage, so it is waited for.
# WM_VM_BOOT_MINUTES (20) in all.
wait_ready() {
    vm_conf "$1"
    running || die "machine $1 is not running"
    local minutes=${WM_VM_BOOT_MINUTES:-20}
    [[ $minutes =~ ^[1-9][0-9]*$ ]] || die "WM_VM_BOOT_MINUTES: a number of minutes, e.g. 20 ('$minutes')"
    local started=$SECONDS limit=$((minutes * 60)) a=$dir/boot-screen-a.ppm b=$dir/boot-screen-b.ppm
    local dump_a dump_b last='' since=$SECONDS sum reset=0
    dump_a=$(screendump_json "$a")
    dump_b=$(screendump_json "$b")
    while (( SECONDS - started < limit )); do
        if ssh_answers 'exit 0'; then
            rm -f "$a" "$b"
            echo "Machine $1 answers over SSH (after $((SECONDS - started)) s)."
            return 0
        fi
        running || die "machine $1 stopped while starting"
        rm -f "$a" "$b"
        sum=''
        if qmp "$dump_a" sleep:1 "$dump_b" >/dev/null 2>&1 && [[ -f $a && -f $b ]] && cmp -s "$a" "$b"; then
            sum=$(md5sum < "$a" | cut -d' ' -f1)
        fi
        if [[ -z $sum || $sum != "$last" ]]; then
            last=$sum; since=$SECONDS
        elif (( SECONDS - since >= 300 )); then
            (( reset == 0 )) || { rm -f "$a" "$b"; die "machine $1 hung again after a reset (no SSH, the screen unchanged for 5 minutes); look: $0 screenshot $1 screen.png"; }
            reset=1
            echo "Machine $1 seems hung while starting (no SSH, the screen unchanged for 5 minutes): reset." >&2
            # cont: a machine paused by hand would stay paused after the reset
            qmp '{"execute":"system_reset"}' '{"execute":"cont"}' >/dev/null
            last=''; since=$SECONDS
        fi
        sleep 10
    done
    rm -f "$a" "$b"
    die "machine $1 did not answer over SSH within $minutes minutes; look: $0 screenshot $1 screen.png"
}

# Restarts Windows over SSH and waits for the new one: first until the old one stops answering (right after the
# command it still does), then as start does. Installing updates on the way down may take minutes.
cmd_restart() {
    vm_conf "$1"
    running || die "machine $1 is not running"
    # Its connection may break as Windows goes down: whether the restart came is told by SSH going away
    ssh_answers 'shutdown.exe /r /f /t 0' || true
    local waited=0
    while ssh_answers 'exit 0'; do
        (( waited < 900 )) || die "machine $1 still answers 15 minutes after the restart command (did it take it?)"
        sleep 5; waited=$((waited + 5))
    done
    echo "Machine $1 is restarting..."
    wait_ready "$1"
}

cmd_stop() {
    vm_conf "$1"
    if running; then
        # A full shutdown: the power button only hibernates the kernel when Fast Startup is on (the Windows
        # default), so a pending computer name or update would wait, and a saved state would hold a hibernated system
        # (/f: an open window or dialog in the signed-in session must not hold the shutdown up)
        ssh_answers 'shutdown.exe /s /f /t 0' || qmp '{"execute":"system_powerdown"}' >/dev/null || true
        # Windows installs pending updates while it shuts down, which can take minutes; cutting the power then
        # could break the installation, so it gets 15 minutes before qemu is stopped
        local waited=0
        while running && (( waited < 900 )); do
            sleep 5; waited=$((waited + 5))
            if (( waited % 120 == 0 )); then echo "Windows is still shutting down ($((waited / 60)) min; probably installing updates)..."; fi
        done
        if running; then
            echo "Windows did not shut down within 15 minutes; stopping the machine." >&2
            qmp '{"execute":"quit"}' >/dev/null 2>&1 || kill "$(cat "$dir/qemu.pid")" 2>/dev/null || true
            for _ in $(seq 1 20); do running || break; sleep 0.5; done
        fi
        # qemu still holding the disk: snapshot or revert now would damage it, so keep the pid file and stop here
        running && die "qemu (pid $(cat "$dir/qemu.pid")) is still running; stop it by hand (kill -9)"
    fi
    stop_swtpm
    rm -f "$dir/qemu.pid"
    echo "Machine $1 stopped."
}

stop_swtpm() {
    [[ -f $dir/swtpm.pid ]] && kill "$(cat "$dir/swtpm.pid")" 2>/dev/null || true
    rm -f "$dir/swtpm.pid"
}

cmd_status() {
    for n in pro home; do
        vm_conf "$n"
        if [[ ! -f $dir/disk.qcow2 ]]; then echo "$n: not created"
        elif running; then echo "$n: running (SSH $ssh_port)"
        else echo "$n: stopped"; fi
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
    [[ -f $config ]] || die "configuration file $config not found"
    stage=$(mktemp -d)
    trap "rm -rf $(printf '%q' "$stage")" EXIT   # also when ssh or scp fails: the copy holds the configuration
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
    echo "Machine $1: wmanager in C:\wmanager (configuration: $config)."
}

# Runs a wmanager script from C:\wmanager as administrator over SSH (no console: default answers, as in a scheduled
# task); the output comes back converted from the Windows console code page; the exit code is the script's.
cmd_run() {
    vm_conf "$1"; shift
    local script=$1 a ps; shift
    [[ $script =~ ^[A-Za-z0-9._-]+\.ps1$ ]] || die "script: the name of a .ps1 file in C:\wmanager (e.g. Provision.ps1)"
    ps="powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\wmanager\\$script"
    for a in "$@"; do ps+=" '${a//\'/\'\'}'"; done
    ps+='; exit $LASTEXITCODE'
    set_ssh_opts
    local rc
    set +e
    ssh "${ssh_opts[@]}" -p "$ssh_port" tester@127.0.0.1 "$ps" </dev/null 2>&1 | iconv -c -f CP852 -t UTF-8 | tr -d '\r'
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}

cmd_screenshot() {
    vm_conf "$1"
    running || die "machine $1 is not running"
    local out
    out=$(realpath -m "$2")
    qmp "$(screendump_json "$out" png)" >/dev/null
    echo "$out"
}

cmd_snapshot() {
    vm_conf "$1"
    running && die "stop the machine before saving a state (tests/vm/vm.sh stop $1)"
    [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || die "state name: letters, digits, . - _"
    # qemu-img would add a second snapshot with the same name, and revert would pair the old disk with the new TPM
    if [[ -d $dir/snapshots/$2 ]] || qemu-img snapshot -l "$dir/disk.qcow2" | awk 'NR > 2 { print $2 }' | grep -qx -- "$2"; then
        die "state $2 already exists (delete it: tests/vm/vm.sh forget $1 $2)"
    fi
    qemu-img snapshot -c "$2" "$dir/disk.qcow2"
    mkdir -p "$dir/snapshots/$2"
    cp "$dir/OVMF_VARS.fd" "$dir/snapshots/$2/"
    tar -C "$dir" -cf "$dir/snapshots/$2/tpm.tar" tpm
    echo "Saved state $2 of machine $1."
}

cmd_revert() {
    vm_conf "$1"
    running && die "stop the machine before going back to a state (tests/vm/vm.sh stop $1)"
    [[ -d $dir/snapshots/$2 ]] || die "no state $2 (tests/vm/vm.sh snapshots $1)"
    qemu-img snapshot -a "$2" "$dir/disk.qcow2"
    cp "$dir/snapshots/$2/OVMF_VARS.fd" "$dir/"
    rm -rf "$dir/tpm"
    tar -C "$dir" -xf "$dir/snapshots/$2/tpm.tar"
    echo "Machine $1 is back at state $2."
}

cmd_forget() {
    vm_conf "$1"
    running && die "stop the machine before deleting a state (tests/vm/vm.sh stop $1)"
    [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || die "state name: letters, digits, . - _"
    while qemu-img snapshot -l "$dir/disk.qcow2" | awk 'NR > 2 { print $2 }' | grep -qx -- "$2"; do
        qemu-img snapshot -d "$2" "$dir/disk.qcow2"
    done
    rm -rf "${dir:?}/snapshots/$2"
    echo "Deleted state $2 of machine $1."
}

cmd_snapshots() {
    vm_conf "$1"
    qemu-img snapshot -U -l "$dir/disk.qcow2"   # -U: also while the machine runs
}

# After the installation: boot from the disk only
cmd_installed() {
    vm_conf "$1"
    rm -f "$dir/install.iso"
    echo "Machine $1: installation discs detached (from the next start)."
}

[[ $# -ge 1 ]] || { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 1; }
cmd=$1; shift
case $cmd in
    create)     [[ $# -ge 2 && $# -le 3 ]] || die "usage: $0 create <pro|home> <iso> [memory-MB]"; cmd_create "$@" ;;
    start)      [[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 start <vm> [memory-MB]"; cmd_start "$@" ;;
    wait)       [[ $# -eq 1 ]] || die "usage: $0 wait <vm>"; wait_ready "$1" ;;
    restart)    [[ $# -eq 1 ]] || die "usage: $0 restart <vm>"; cmd_restart "$1" ;;
    stop)       [[ $# -eq 1 ]] || die "usage: $0 stop <vm>"; cmd_stop "$1" ;;
    status)     cmd_status ;;
    ssh)        [[ $# -ge 1 ]] || die "usage: $0 ssh <vm> [command]"; cmd_ssh "$@" ;;
    copy)       [[ $# -eq 3 ]] || die "usage: $0 copy <vm> <local-path> <win-path>"; cmd_copy "$@" ;;
    deploy)     [[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 deploy <vm> [provision.config.psd1]"; cmd_deploy "$@" ;;
    run)        [[ $# -ge 2 ]] || die "usage: $0 run <vm> <script.ps1> [params]"; cmd_run "$@" ;;
    screenshot) [[ $# -eq 2 ]] || die "usage: $0 screenshot <vm> <file.png>"; cmd_screenshot "$@" ;;
    snapshot)   [[ $# -eq 2 ]] || die "usage: $0 snapshot <vm> <name>"; cmd_snapshot "$@" ;;
    revert)     [[ $# -eq 2 ]] || die "usage: $0 revert <vm> <name>"; cmd_revert "$@" ;;
    forget)     [[ $# -eq 2 ]] || die "usage: $0 forget <vm> <name>"; cmd_forget "$@" ;;
    snapshots)  [[ $# -eq 1 ]] || die "usage: $0 snapshots <vm>"; cmd_snapshots "$1" ;;
    installed)  [[ $# -eq 1 ]] || die "usage: $0 installed <vm>"; cmd_installed "$1" ;;
    *) die "unknown command '$cmd'" ;;
esac
