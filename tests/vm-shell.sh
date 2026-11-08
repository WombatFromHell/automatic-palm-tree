#!/usr/bin/env bash
# The human-facing VM runner: boot tests/vm-shell.nix and hand its serial console to whoever ran
# this. It is the interactive half of the VM tier; tests/vm-run.sh stays the gate, and the scripted
# smoke (tests/vm-check.bats) drives this same runner with --script so the harness is exercised
# rather than assumed.
#
#   tests/vm-shell.sh                # your keyboard is the guest's console
#   tests/vm-shell.sh --script FILE  # FILE is typed into the console, then the console closes
#
# End a run by typing `poweroff` in the guest (it shuts the VM down, so qemu exits at once) or with
# Ctrl-]. Either way the run dir is deleted on exit, and "poweroff" stops the guest, never the host:
# this machine is the caller's, not the guest's (ADR-953e34c78819). Run it with SELinux permissive,
# like the gate:
#
#   sudo setenforce 0 && tests/vm-shell.sh && sudo setenforce 1
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/vm-lib.bash
source "$repo/tests/vm-lib.bash"

script=""
while [ $# -gt 0 ]; do
  case "$1" in
  --script)
    script=${2:-}
    [ -n "$script" ] || {
      printf 'vm-shell.sh: --script needs a file\n' >&2
      exit 2
    }
    shift 2
    ;;
  *)
    printf 'vm-shell.sh: unknown argument %s\n' "$1" >&2
    exit 2
    ;;
  esac
done

vm_selinux_check || exit 1
if [ ! -e /dev/kvm ]; then
  printf 'vm-shell.sh: /dev/kvm is absent — this tier needs hardware acceleration.\n' >&2
  exit 1
fi

run="$vm_tmp/vm-shell-$(date +%s)"
log=$(vm_log_path vm-shell)
mkdir -p "$run/tmp/xchg" "$vm_tmp/logs"
# A run costs a store image plus a blank drive, and the log lives in $vm_tmp/logs, so dropping the
# run dir on exit loses nothing the report needs.
trap 'rm -rf "$run"' EXIT

# The repo the guest installs from, without git history: the guest only ever reads the working
# tree. The trailing /. copies the contents — `cp -a dir existing-dir` nests the directory inside
# it, which is how a mounted share ends up with nothing at its top level.
cp -a "$repo/." "$run/tmp/xchg"
rm -rf "$run/tmp/xchg/.git"

{
  printf 'run=%s\n' "$run"
  printf 'caps: MemoryMax=1300M MemorySwapMax=0 timeout=300s\n'
  printf 'kvm=%s\n' "$(ls -l /dev/kvm)"
} >"$log"

vm_build ./tests/vm-shell.nix "$run/guest" >>"$log" 2>&1

# The console fifo is created before anything opens it: opening a fifo that is not there with `>`
# creates a regular file, and qemu then reads an empty stdin and exits at once. fd 9 holds the write
# end open so the guest never sees EOF until this script decides the console is done.
fifo="$run/console.fifo"
mkfifo "$fifo"
# tee, not a plain redirect: the console is the interface, so the person who ran this sees it while
# the host still keeps the transcript.
vm_boot "$run/guest" "$run/tmp" "$log" 300 "$fifo" tee &
boot=$!
vm_serial_open "$fifo"

# RAM is sampled while the guest is up, from the host's own cgroup (the guest's /proc reports its
# own namespace limit).
vm_free_peak 300 qemu >>"$log" 2>&1 &
peak=$!

# Wait for the autologin shell before anything is typed: serial-getty prints its prompt before the
# shell behind it exists, so lines typed at the first prompt are eaten by login and the guest then
# sits idle at a prompt — which looks exactly like a hung run.
vm_wait_for "$log" "root@" 90 || {
  printf 'vm-shell.sh: no autologin prompt in the console\n' >>"$log"
  exit 1
}

if [ -n "$script" ]; then
  cat "$script" >&9
else
  # Forward the terminal until qemu closes the console; a write into a closed fifo dies with SIGPIPE.
  cat >&9
fi
exec 9>&-
wait "$peak"
wait "$boot" || printf 'boot ended by timeout\n' >>"$log"
printf 'log=%s\n' "$log"
