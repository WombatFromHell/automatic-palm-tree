#!/usr/bin/env bash
# Shared VM harness for the tiers that boot a guest on this machine. Three properties, all measured
# on this host (see .pi/PLAN-vm-e2e.md):
#
#   MemoryMax lives in a transient systemd scope. systemd-kill's MemoryMax= is silently a no-op, and
#   the kernel's EOL 'MemoryMax=' on the command line aborts systemd (exit 78), so the property goes
#   through systemd-run. A scope, not a service: systemd-run --user would put the unit under
#   user-1000.slice, which is already at its limit, and the OOM killer would kill that slice.
#   MemorySwapMax=0 makes hitting the cap a kill rather than a swap storm on a RAM-constrained host.
#
#   The guest state is fresh per run and small: a blank drive written by qemu-img every run,
#   --initrd-inject for the payload, no disk backing for the store, so nothing carries over.
#
#   The caller's log is a file on the host that called it, and guest RAM is sampled from the host's
#   own cgroup — the guest's /proc is inside a memory namespace and reports its own limit.
#
# SELinux must be Permissive for an unprivileged qemu to open the /dev/shm share it needs to boot.
# That is a host setting this repo does not own: vm_selinux_check reports the mode and refuses to
# run where enforcing would produce a "permission denied" that reads as a harness bug.

vm_tmp=${VM_TMP:-/var/mnt/data0/temp/flakeroot-tmp}
vm_repo=${VM_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# Every build below runs inside a systemd scope, which inherits this shell's environment. A caller
# whose PATH lacks nix (a bare login shell) dies mid-build with "nix: command not found", so the
# standard profile bin is guaranteed here, not by the caller. An injected PATH that already resolves
# nix is left alone: that is how vm-check.bats stubs a dead nix, and the stub is what must be found.
if ! command -v nix >/dev/null 2>&1; then
  PATH="/nix/var/nix/profiles/default/bin:$PATH"
fi

# RAM each run asks for before it creates anything, so every runner refuses with the same number:
# a guest alone is scoped at 1300M, and a --push run holds that guest plus a host-side build scope
# (1200M) at the same time. If the gate's threshold and the runner's ever disagree, the runner
# refuses mid-run and the tier reports an obscure "no log" instead of a headroom refusal.
vm_headroom_guest=1400
vm_headroom_push=2500

vm_log_path() { printf '%s/logs/%s-%s.log\n' "$vm_tmp" "$1" "$(date +%s)"; }

# One line to the terminal and, once a log exists, to the log too. Both VM runners print the same
# stream, so the person waiting on the run and the log that survives it read the same words. The log
# check is conditional because vm-shell.sh prints its steps before the log path exists.
vm_say() {
  printf '%s\n' "$1"
  if [ -n "${log:-}" ]; then printf '%s\n' "$1" >>"$log"; fi
}

vm_scope() {
  # TimeoutStopSec bounds a `systemctl stop` (S1's vm-run.sh stop): KillMode defaults to
  # control-group, so stop SIGTERMs every process in the cgroup and SIGKILLs the rest after this.
  systemd-run --user --scope -q --unit="$1" -p MemoryMax="$2" -p MemorySwapMax=0 -p TimeoutStopSec=5 "${@:3}"
}

# The mode qemu needs, reported rather than assumed.
vm_selinux_check() {
  local mode
  mode=$(getenforce 2>/dev/null || printf 'absent')
  if [ "$mode" = Permissive ] || [ "$mode" = Disabled ]; then
    printf 'selinux=%s\n' "$mode"
    return 0
  fi
  printf 'selinux=%s — this tier needs SELinux permissive for qemu to open its /dev/shm share.\n' "$mode"
  printf 'Restore it afterwards with: sudo setenforce 1\n'
  return 1
}

# RAM the tier may spend, read from the host's own meminfo (VM_MEMINFO stands in for it in tests).
# The tier's footprint is a guest at MemoryMax plus the host-side pack scope, so it wants cap plus a
# gigabyte. Swap is demanded even though the scope runs with MemorySwapMax=0: systemd-oomd kills the
# largest holder under user.slice when RAM *and* swap both cross its thresholds (journal:
# 29.1G/32.7G and 7.5G/8.6G, both over 87%), and the holder on this host is the local model server,
# not the guest. A host with swap nearly full is already in that state.
vm_headroom_check() {
  local need=${1:-2324} swap_need=${2:-1024} line
  line=$(awk -v need="$need" -v swap_need="$swap_need" '
    /^MemAvailable:/ { ram = int($2 / 1024) }
    /^SwapTotal:/    { swap_total = int($2 / 1024) }
    /^SwapFree:/     { swap_free = int($2 / 1024) }
    END {
      # No swap on this host means oomd never reaches its swap threshold, so there is nothing to ask for.
      if (ram < need || (swap_total > 0 && swap_free < swap_need)) {
        printf "short: ram=%d swap=%d, needs %d/%d\n", ram, swap_free, need, swap_need
      } else {
        printf "ok: ram=%d swap=%d\n", ram, swap_free
      }
    }' "${VM_MEMINFO:-/proc/meminfo}")
  case "$line" in
  short:*)
    vm_say "FAIL headroom${line#short} — the tier boots a guest plus a host-side pack scope; free RAM (or stop the largest holder under user.slice) before running it"
    return 1
    ;;
  esac
  vm_say "headroom${line#ok}"
  return 0
}

# Build only the VM script (config.system.build.vm). nixpkgs' legacy lib.nixosSystem injects a
# module that reads `config.nixpkgs.flake.source`, which fails on a dirty tree when `nix build`
# realises the derivation, so the config is evaluated through eval-config.nix directly — same
# pinned nixpkgs, no second instance, no flake source in the closure.
# An optional third argument is an override module file (any absolute path, since the eval is
# --impure), which is how the runner injects a per-run SSH key or a pushed closure without touching
# the checked-in config.
vm_build() {
  local config=$1 out=$2 override=${3:-}
  # Backgrounded and waited for, not foregrounded: bash defers a trap until the foreground command
  # finishes, so a Ctrl+C during a minutes-long build would do nothing until the build returned. wait
  # returns on a signal, so the caller's INT trap can end the build scope right away.
  vm_scope "vm-build-$$" 1200M bash -c \
    "cd $vm_repo && nix build --impure --expr 'let f = builtins.getFlake (toString ./.); np = f.inputs.nixpkgs; in (import (np + \"/nixos/lib/eval-config.nix\") { lib = np.lib; system = \"x86_64-linux\"; modules = [ $config${override:+ $override} ]; }).config.system.build.vm' -o $out" &
  wait "$!"
}

# Boot it: the VM script creates its own blank drive (`emptyDiskImages`), the payload is injected
# into the kernel, and memory is capped. TMPDIR + USE_TMPDIR put the store image, the drive and the
# xchg share in the run dir. `-nographic` makes qemu's stdio the serial console, so a console the
# host can type into means a fifo on qemu's stdin — not a socket, which this nixpkgs does not open.
#
# The fifo needs a writer open before qemu starts or qemu blocks at startup, so the caller holds fd
# 9 for the life of the run (vm_console_open, opened after this boot is launched).
# The fifo must already exist: opening a fifo that is not there creates a regular file, which is
# how qemu ends up reading an empty stdin and exits at once.
vm_boot() {
  local guest=$1 run_dir=$2 serial=$3 timeout=${4:-300} fifo=${5:-} mode=${6:-redirect}
  local cmd="TMPDIR=$run_dir USE_TMPDIR=1 timeout $timeout $guest/bin/run-*-vm${fifo:+ < $fifo}"
  # The scope has to hold qemu plus the guest's whole RAM (memorySize) plus its page cache: a
  # 1300M scope around a 1024 MB guest leaves ~276 MB. VM_BOOT_CEILING is the separate cap for
  # the installed drive (vm_boot_disk).
  local ceiling=1300M
  if [ "$mode" = tee ]; then
    # The console is the interface: the caller sees it while the host keeps the transcript.
    vm_scope "vm-boot-$$" "$ceiling" bash -c "$cmd" 2>&1 | tee -a "$serial"
  else
    vm_scope "vm-boot-$$" "$ceiling" bash -c "$cmd" >>"$serial" 2>&1
  fi
}

# Open the console: hold the fifo's write end on fd 9 for the life of the run so the guest never
# sees EOF until the caller decides the console is done. Write end only, and only after the reader
# has been launched: opening a fifo with `>` blocks until something has it open for reading, so a
# writer opened first hangs the script before qemu ever starts. mkfifo stays at the call sites —
# opening a fifo that is not there with `>` creates a regular file, and qemu then reads an empty
# stdin and exits at once.
vm_console_open() {
  exec 9>"$1"
}

# End a boot by its scope, not by pattern: a guest that has nothing to power it off would otherwise
# run out the timeout backstop, and pgrep for qemu kills every VM on this host, including another
# test's. The `.scope` suffix is required — systemd reads a bare name as `.service` and kills nothing
# — and `-s KILL` rather than `--kill-mode=kill`, which this host's systemctl (systemd 262) rejects.
# A silently swallowed kill is what made a boot run on for 200s after its proof was in.
vm_kill_scope() {
  # SIGINT can still be pending when a trap calls this, and it lands on systemctl before systemctl
  # sends the kill — measured, the scope stayed active with the marker printed. Ignoring the tty
  # signals in this subshell is what lets the kill go out.
  (
    trap '' INT TERM
    systemctl --user kill -s KILL "$1.scope" 2>/dev/null || true
  )
}

# Ctrl+C cannot be answered by a trap. bash is killed by the signal without running one (measured on
# both runners: the run dir and the guest survived), and the guest lives in a systemd scope with its
# own process group, so no tty signal can reach qemu — systemctl is the only way out. This watcher
# ignores the tty signals, notices the harness vanished, and ends the scopes and the run dir itself.
# Units already gone are a silent no-op, so a normal exit is unaffected.
vm_watch_harness() {
  local harness=$1 run=$2
  trap '' INT TERM
  while kill -0 "$harness" 2>/dev/null; do sleep 1; done
  vm_kill_scope "vm-build-$harness"
  vm_kill_scope "vm-boot-$harness"
  vm_kill_scope "vm-disk-boot-$harness"
  rm -rf "$run"
}

# End every scope this run still owns. Kept for the paths bash does run a trap on.
vm_kill_all() {
  vm_kill_scope "vm-build-$$"
  vm_kill_scope "vm-boot-$$"
  vm_kill_scope "vm-disk-boot-$$"
}

# A scope has no main process and its lifecycle is bound to the existence of any process inside it
# (systemd.scope(5)), so terminating one never touches the scratch dir its spawner made on the host.
# Those dirs are named vm-<kind>-<pid>, so an owner that is gone is the whole ownership test.
vm_remove_orphan_runs() {
  local dir base pid removed=0
  for dir in "$vm_tmp"/vm-*/; do
    [ -d "$dir" ] || continue
    base=${dir%/}
    pid=${base##*-}
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || {
      rm -rf "$dir"
      removed=$((removed + 1))
    }
  done
  printf 'removed=%s\n' "$removed"
}

# End every scope this tier owns with systemd's own mechanism, then clear the host-side leftovers.
# Called by `vm-run.sh stop`, and by the gate's interrupt handler.
vm_stop_all() {
  # Cleanup runs on exit, after the scopes are confirmed closed, so nothing is deleted out from
  # under a guest that is still shutting down.
  trap 'vm_remove_orphan_runs' EXIT
  (
    # A pending Ctrl+C lands on systemctl before systemctl sends the kill (measured), so the
    # calls that talk to systemd run with the tty signals ignored.
    trap '' INT TERM
    local units u
    units=$(systemctl --user list-units --type=scope --no-pager --all 2>/dev/null |
      grep -oE 'vm-[a-z]+-[0-9]+\.scope' | sort -u || true)
    if [ -z "$units" ]; then
      printf 'stopped=0\n'
      exit 0
    fi
    # shellcheck disable=SC2086  # intentional word splitting: one line per unit
    printf 'stop: %s\n' $units
    # shellcheck disable=SC2086  # intentional word splitting: one systemctl call for all units
    # KillMode=control-group (the default, systemd.kill(5)) reaches every process in the cgroup;
    # `wait` blocks until the unit is inactive, i.e. until the cgroup is empty.
    systemctl --user stop $units 2>/dev/null || true
    for u in $units; do systemctl --user wait "$u" 2>/dev/null || true; done
    # shellcheck disable=SC2086  # intentional word splitting: the count is the unit list's length
    printf 'stopped=%s\n' "$(printf '%s\n' $units | wc -l)"
  )
}

# Interrupted: end the guest, then leave with the shell's own 130.
vm_abort() {
  printf 'interrupted — ending scopes for pid %s\n' "$$" >&2
  vm_kill_all
  exit 130
}

# End a boot: kill the scope, then wait for the peak sampler and the boot pipeline. Killing first is
# the point — a guest that never powers off (the installed drive sits at its login prompt) keeps qemu
# alive until the boot timeout fires, and waiting for the sampler before killing idled a full
# VM_BOOT_TIMEOUT. The kill also closes nix's run-*-vm, which hangs in `wait` once qemu exits and
# nothing else ends the pipeline. A guest that powered off cleanly leaves no scope, and systemctl
# exits 1 on a name it cannot find — under set -e that would fail a run whose every marker passed.
# $log is the caller's transcript.
vm_end_boot() {
  # Kill first — a guest that never powers off (the installed drive sits at its login prompt) keeps
  # qemu alive until the boot timeout fires, and waiting for the sampler before killing idled a full
  # VM_BOOT_TIMEOUT. systemd-run forks the guest itself, so a kill that arrives before systemd has
  # registered the unit exits 0 without signalling anything (measured here: kill rc=0, guest still
  # running), and a teardown that outruns registration also leaves the sampler without ever seeing the
  # guest, so it burns its whole window. Poll the unit instead: kill while it is active, stop once it
  # is inactive, capped so a hung guest cannot extend the run. A guest that powered off cleanly leaves
  # no scope, and systemctl exits 1 on a name it cannot find — under set -e that would fail a run
  # whose every marker passed.
  # $log is the caller's transcript.
  local deadline=$((SECONDS + 10)) state=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$(systemctl --user show -p ActiveState --value "$1.scope" 2>/dev/null)
    # A unit systemd has not registered yet also reads "inactive", and killing it exits 0 without
    # signalling anything. Stop only when the unit is gone *and* the pipeline is gone.
    if [ "$state" = inactive ] && ! kill -0 "$3" 2>/dev/null; then break; fi
    vm_kill_scope "$1" || true
    sleep 1
  done
  # Last resort: a guest whose unit systemd never registered cannot be signalled through systemd.
  # Its pipeline is a `timeout` wrapper, which forwards the signal to qemu.
  for child in $(pgrep -P "$3" 2>/dev/null || true); do kill "$child" 2>/dev/null || true; done
  wait "$2"
  wait "$3" || printf 'boot ended without poweroff\n' >>"$log"
}

# Guest RAM as the host sees it, sampled while the VM is alive: the guest's own /proc is inside a
# memory namespace and reports its own limit. The scope's cgroup is found from the qemu process —
# sampling user.slice instead reports every megabyte that user happens to be running, which reads
# as a gigabyte the guest never used. The pattern is the guest *binary*, `qemu-system`, not `qemu`:
# pgrep -f also matches a nix build whose command line carries /nix/store/…-qemu-…, and that process
# lives in user.slice. $3 is the boot pipeline's pid: the sampler ends when that job ends, so a
# teardown kill that lands between polls cannot leave it burning its whole window.
vm_free_peak() {
  local duration=${1:-30} pattern=${2:-qemu-system} alive=${3:-} peak=0 cur pid cg seen=0 gone=0
  local deadline=$((SECONDS + duration))
  while [ "$SECONDS" -lt "$deadline" ]; do
    # pgrep exits 1 while the VM has not spawned qemu yet, and pipefail turns that into a failed
    # assignment, which under `set -e` kills the sampler before it prints any peak at all. The
    # caller reads peak_guest_mb from the log, so a missed first poll must not be fatal.
    pid=$(pgrep -f "$pattern" | head -1 || true)
    if [ -n "$pid" ]; then
      seen=1
      gone=0
      # Unguarded, a pid that vanishes between pgrep and the read makes awk exit 2, pipefail turns
      # that into a failed assignment, and `set -e` kills the sampler — which cost the gate its
      # verdict on a run whose every test passed.
      cg=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup" 2>/dev/null | head -1 || true)
      # memory.peak is the cgroup's high-water mark, so a poll between spikes cannot miss one;
      # memory.current is the fallback for a kernel without it, and the max keeps either honest.
      cur=$(cat "/sys/fs/cgroup${cg}/memory.peak" 2>/dev/null || cat "/sys/fs/cgroup${cg}/memory.current" 2>/dev/null || printf 0)
      [ "$cur" -gt "$peak" ] && peak=$cur
    else
      # Three blank polls guard against a pgrep miss between process restarts.
      gone=$((gone + 1))
      if [ "$gone" -ge 3 ] && [ "$seen" = 1 ]; then break; fi
    fi
    if [ -n "$alive" ]; then
      # A shell that has exited but not yet been waited for is a zombie, so either state means the
      # boot is over.
      case "$(awk '/^State:/ { print $2 }' "/proc/$alive/status" 2>/dev/null)" in
      Z | "") break ;;
      esac
    fi
    sleep 1
  done
  awk -v p="$peak" 'BEGIN { printf "peak_guest_mb=%.0f\n", p / 1048576 }'
}

# Boot an installed drive: qemu direct kernel boot from a kernel and initrd copied out of the
# installed closure. No firmware: this pinned nixpkgs has no plain OVMF, so the boot loader entries
# on the ESP are not what boots here (see .pi/PLAN-vm-push.md D7). No extra drive either: the
# installed fstab names partitions by UUID, so the device name the drive lands on says nothing.
vm_boot_disk() {
  local kernel=$1 initrd=$2 append=$3 drive=$4 log=$5 timeout=${6:-300} qemu=${7:-}
  local ceiling=${VM_BOOT_CEILING:-2000M}
  # Strip the suffix with parameter expansion: $((2000M)) is an arithmetic error, and a function
  # that dies here leaves the caller waiting on a boot that never started.
  vm_scope "vm-disk-boot-$$" "$ceiling" bash -c \
    "timeout $timeout $qemu -machine accel=kvm -cpu max -m $((${ceiling%M} - 400)) -drive file=$drive,format=qcow2,id=drive1,if=none,index=1 -device virtio-blk-pci,bootindex=1,drive=drive1 -kernel $kernel -initrd $initrd -append '$append console=tty0 console=ttyS0,115200n8' -nographic" \
    2>&1 | tee -a "$log"
}

# Wait until a pattern shows up in the serial log the host is already capturing.
vm_wait_for() {
  local file=$1 pattern=$2 timeout=${3:-60} since=${4:-0} waited=0
  # `since` is a byte offset: a second boot in the same log must be judged on what it wrote, not on
  # text an earlier boot left behind.
  while [ "$waited" -lt "$timeout" ]; do
    if [ "$since" -gt 0 ]; then
      tail -c +"$((since + 1))" "$file" | grep -q -- "$pattern" && return 0
    else
      grep -q -- "$pattern" "$file" && return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Type the login into the console and prove a shell came back by a marker the guest prints back.
# The password is typed by us and never echoed by the guest, so the log carries the login and not
# the secret. The guest's own marker is waited for first: serial-getty prints its prompt before a
# oneshot ordered at multi-user.target has run, so typing at the first prompt always comes back
# "Login incorrect".
vm_serial_login() {
  local log=$1 user=$2 pass=$3 timeout=${4:-60} tag=${5:-VM_SERIAL_LOGIN_OK} wait_pattern=${6:-SPIKE DONE} since=${7:-0}
  [ -n "$wait_pattern" ] && { vm_wait_for "$log" "$wait_pattern" "$timeout" "$since" || return 1; }
  # The prompt has to be one that is live now, not text an earlier timed-out getty left in the
  # log, so only the tail counts — and only the tail past `since`, because a second boot in the
  # same log would otherwise read the first boot's prompts as its own.
  local from=$((since + 1))
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ] && ! tail -c +"$from" "$log" | tail -n 30 | grep -aq 'login:'; do sleep 1; done
  tail -c +"$from" "$log" | tail -n 30 | grep -aq 'login:' || return 1
  printf '%s\n' "$user" >&9
  vm_wait_for "$log" "Password:" "$timeout" || return 1
  printf '%s\n' "$pass" >&9
  # The prompt is what proves a shell came back. Not "# ": a colourised PS1 emits escape
  # sequences and ends in "#" with no trailing space, so that pattern never matches.
  vm_wait_for "$log" "$user@" "$timeout" "$since" || return 1
  # uptime proves the shell is a live session, and poweroff ends the run instead of waiting for the
  # boot timeout — both must run in this shell, because `exit` first would put poweroff on the
  # respawned login prompt, where it is read as a username. qemu exits when the guest shuts down;
  # `timeout 300` stays as the backstop for a guest that never gets here.
  printf 'uptime; echo %s; poweroff\n' "$tag" >&9
  vm_wait_for "$log" "$tag" "$timeout" "$since" || return 1
  # uptime prints before the marker, so the marker already proves it ran; this checks the output.
  grep -aq 'load average' "$log" || return 1
}
