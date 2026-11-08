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

vm_log_path() { printf '%s/logs/%s-%s.log\n' "$vm_tmp" "$1" "$(date +%s)"; }

vm_scope() {
	systemd-run --user --scope -q --unit="$1" -p MemoryMax="$2" -p MemorySwapMax=0 "${@:3}"
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

# Build only the VM script (config.system.build.vm). nixpkgs' legacy lib.nixosSystem injects a
# module that reads `config.nixpkgs.flake.source`, which fails on a dirty tree when `nix build`
# realises the derivation, so the config is evaluated through eval-config.nix directly — same
# pinned nixpkgs, no second instance, no flake source in the closure.
vm_build() {
	local config=$1 out=$2
	vm_scope "vm-build-$$" 1200M bash -c \
		"cd $vm_repo && nix build --impure --expr 'let f = builtins.getFlake (toString ./.); np = f.inputs.nixpkgs; in (import (np + \"/nixos/lib/eval-config.nix\") { lib = np.lib; system = \"x86_64-linux\"; modules = [ $config ]; }).config.system.build.vm' -o $out"
}

# Boot it: the VM script creates its own blank drive (`emptyDiskImages`), the payload is injected
# into the kernel, and memory is capped. TMPDIR + USE_TMPDIR put the store image, the drive and the
# xchg share in the run dir. `-nographic` makes qemu's stdio the serial console, so a console the
# host can type into means a fifo on qemu's stdin — not a socket, which this nixpkgs does not open.
#
# The fifo needs a writer open before qemu starts or qemu blocks at startup, so the caller holds fd
# 9 for the life of the run (vm_serial_open).
# The fifo must already exist: opening a fifo that is not there creates a regular file, which is
# how qemu ends up reading an empty stdin and exits at once.
vm_boot() {
	local guest=$1 run_dir=$2 serial=$3 timeout=${4:-300} fifo=${5:-}
	vm_scope "vm-boot-$$" 1300M bash -c \
		"TMPDIR=$run_dir USE_TMPDIR=1 timeout $timeout $guest/bin/run-*-vm${fifo:+ < $fifo}" >>"$serial" 2>&1
}

vm_serial_open() { exec 9>"$1"; }

# Guest RAM as the host sees it, sampled while the VM is alive: the guest's own /proc is inside a
# memory namespace and reports its own limit. The scope's cgroup is found from the qemu process —
# sampling user.slice instead reports every megabyte that user happens to be running, which reads
# as a gigabyte the guest never used.
vm_free_peak() {
	local duration=${1:-30} pattern=${2:-qemu} peak=0 cur pid cg seen=0 gone=0
	local deadline=$((SECONDS + duration))
	while [ "$SECONDS" -lt "$deadline" ]; do
		# pgrep exits 1 while the VM has not spawned qemu yet, and pipefail turns that into a failed
		# assignment, which under `set -e` kills the sampler before it prints any peak at all. The
		# caller reads peak_guest_mb from the log, so a missed first poll must not be fatal.
		pid=$(pgrep -f "$pattern" | head -1 || true)
		if [ -n "$pid" ]; then
			seen=1
			gone=0
			cg=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup" 2>/dev/null | head -1)
			cur=$(cat "/sys/fs/cgroup${cg}/memory.current" 2>/dev/null || printf 0)
			[ "$cur" -gt "$peak" ] && peak=$cur
		else
			# Once a guest has been seen, its disappearance ends the window: a caller waiting on a
			# fixed duration prints nothing for minutes after the tier finished. Three blank polls
			# guard against a pgrep miss between process restarts.
			gone=$((gone + 1))
			if [ "$seen" = 1 ] && [ "$gone" -ge 3 ]; then break; fi
		fi
		sleep 1
	done
	awk -v p="$peak" 'BEGIN { printf "peak_guest_mb=%.0f\n", p / 1048576 }'
}

# Wait until a pattern shows up in the serial log the host is already capturing.
vm_wait_for() {
	local file=$1 pattern=$2 timeout=${3:-60} waited=0
	while [ "$waited" -lt "$timeout" ]; do
		grep -q -- "$pattern" "$file" && return 0
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
	local log=$1 user=$2 pass=$3 timeout=${4:-60} tag=${5:-VM_SERIAL_LOGIN_OK}
	vm_wait_for "$log" "SPIKE DONE" "$timeout" || return 1
	# The prompt has to be one that is live now, not text an earlier timed-out getty left in the
	# log, so only the tail counts.
	local deadline=$((SECONDS + timeout))
	while [ "$SECONDS" -lt "$deadline" ] && ! tail -n 30 "$log" | grep -aq 'login:'; do sleep 1; done
	tail -n 30 "$log" | grep -aq 'login:' || return 1
	printf '%s\n' "$user" >&9
	vm_wait_for "$log" "Password:" "$timeout" || return 1
	printf '%s\n' "$pass" >&9
	# The prompt is what proves a shell came back. Not "# ": a colourised PS1 emits escape
	# sequences and ends in "#" with no trailing space, so that pattern never matches.
	vm_wait_for "$log" "$user@" "$timeout" || return 1
	printf 'echo %s; exit\n' "$tag" >&9
	vm_wait_for "$log" "$tag" "$timeout"
}
