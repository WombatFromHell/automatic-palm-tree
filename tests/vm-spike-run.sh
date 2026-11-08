#!/usr/bin/env bash
# Spike checkpoint for the VM tier's three properties: memory capped in a scope, fresh state per
# run, log on the host. Deliberately NOT the installer's config — the real config pulls the full
# system closure, which is what the cap exists to keep off this machine. Everything lives in
# tests/vm-lib.bash; this file is the caller, so the lib is what gets exercised.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/vm-lib.bash
source "$repo/tests/vm-lib.bash"

run="$vm_tmp/vm-spike-$(date +%s)"
log=$(vm_log_path vm-spike)
mkdir -p "$run/tmp" "$vm_tmp/logs"
# A failing run leaves a ~1.2G store image plus the blank drive behind; the log lives in
# $vm_tmp/logs, so dropping the run dir on exit costs nothing the report needs.
trap 'rm -rf "$run"' EXIT
# The 9p share is the guest's copy of the scripts the e2e tier will run, plus the password fixture,
# so step 6 and step 5 can prove the payload reached the guest instead of assuming it. systemd
# credentials are not used (see vm-spike.nix), so this is the secret channel.
mkdir -p "$run/tmp/xchg"
cp "$repo/terraform.sh" "$repo/install.sh" "$run/tmp/xchg/"
cp "$repo/tests/vm-spike-secrets.env" "$run/tmp/xchg/secrets.env"
chmod 600 "$run/tmp/xchg/secrets.env"

# The fixture passwords, so the spike logs in with the same accounts the e2e tier will use. The
# file carries comment lines, so only a `user:pass` line counts.
user=$(awk -F: '/^[A-Za-z0-9_-]+:/ { print $1; exit }' "$repo/tests/vm-spike-secrets.env")
pass=$(awk -F: '/^[A-Za-z0-9_-]+:/ { print $2; exit }' "$repo/tests/vm-spike-secrets.env")

{
  printf 'run=%s\n' "$run"
  printf 'caps: MemoryMax=1300M MemorySwapMax=0 timeout=300s\n'
  vm_selinux_check
  printf 'kvm=%s\n' "$(ls -l /dev/kvm)"
} >"$log"

vm_build ./tests/vm-spike.nix "$run/guest" >>"$log" 2>&1

# Boot in the background: the login has to be driven while the VM is alive, and the guest's own
# timeout ends the run. Its exit code is not the assertion — the markers in the log are. qemu's
# stdin is the console (-nographic), so it reads the fifo; fd 9 holds the write end open so qemu
# never sees EOF.
# The console fifo is created before anything opens it: opening a fifo that is not there with `>`
# creates a regular file, and qemu then reads an empty stdin and exits at once.
fifo="$run/console.fifo"
mkfifo "$fifo"
vm_boot "$run/guest" "$run/tmp" "$log" 240 "$fifo" &
boot=$!
vm_serial_open "$fifo"

# RAM is sampled while the guest is up, so it runs alongside the login rather than after it.
vm_free_peak 150 qemu >>"$log" 2>&1 &
peak=$!

# The proof this tier can prove at all: the payload's credentials reached the guest, chpasswd
# applied them, and the serial console answers a login with them. A successful boot is the ceiling
# here; install.sh runs inside a full system closure, so that belongs to the installer tier.
login=fail
if vm_serial_login "$log" "$user" "$pass" 90; then login=ok; fi
wait "$peak"
wait "$boot" || printf 'boot ended by timeout\n' >>"$log"
exec 9>&-

for marker in 'SPIKE OK: closure registered' 'SPIKE OK: fresh root: tmpfs' 'SPIKE OK: writable store' \
  'SPIKE OK: target drive' 'SPIKE OK: secret file delivered' 'SPIKE OK: nixos-install present' \
  'SPIKE OK: passwords applied' 'SPIKE DONE'; do
  if ! grep -q "$marker" "$log"; then
    printf 'SPIKE=failed missing marker: %s\n' "$marker" >>"$log"
    exit 1
  fi
done
if [ "$login" != ok ]; then
  printf 'SPIKE=failed serial login\n' >>"$log"
  exit 1
fi

# The secret must not be in the log the host keeps. The guest never echoes a password; we typed it.
if grep -q "$pass" "$log"; then
  printf 'SPIKE=failed password present in log\n' >>"$log"
  exit 1
fi

printf 'SPIKE=ok login=%s\n' "$login" >>"$log"
printf 'log=%s\n' "$log"
