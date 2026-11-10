#!/usr/bin/env bash
# The human-facing VM runner: boot tests/vm-shell.nix and hand its serial console to whoever ran
# this. It is the interactive half of the VM tier; tests/vm-run.sh stays the gate, and the scripted
# smoke (tests/vm-check.bats) drives this same runner with --script so the harness is exercised
# rather than assumed.
#
#   tests/vm-shell.sh                # your keyboard is the guest's console
#   tests/vm-shell.sh --script FILE  # FILE is typed into the console, then the console closes
#   tests/vm-shell.sh --push HOST --boot  # install it, then boot the drive it was installed onto
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
push_host=""
boot_drive=""
while [ $# -gt 0 ]; do
  case "$1" in
  --push)
    push_host=${2:-}
    [ -n "$push_host" ] || {
      printf 'vm-shell.sh: --push needs a host name\n' >&2
      exit 2
    }
    shift 2
    ;;
  --boot)
    boot_drive=1
    shift
    ;;
  --script)
    script=${2:-}
    [ -n "$script" ] && [ -f "$script" ] || {
      printf 'vm-shell.sh: --script needs a readable file\n' >&2
      exit 2
    }
    # The probe runs from the share the guest already has, so the runner types one line. Typing the
    # whole file makes the guest echo every line back: lines land in a login getty that swallows
    # them, and the probe's own source text lands in the log beside its output.
    case "$script" in
    "$repo"/*) ;;
    *)
      printf 'vm-shell.sh: --script must be a file in the repo - the guest reads it from /repo\n' >&2
      exit 2
      ;;
    esac
    shift 2
    ;;
  *)
    printf 'vm-shell.sh: unknown argument %s\n' "$1" >&2
    exit 2
    ;;
  esac
done

if [ -n "$boot_drive" ] && [ -z "$push_host" ]; then
  printf 'vm-shell.sh: --boot needs --push HOST - the drive it boots is the one deploy installed\n' >&2
  exit 2
fi
vm_selinux_check || exit 1
if [ ! -e /dev/kvm ]; then
  printf 'vm-shell.sh: /dev/kvm is absent — this tier needs hardware acceleration.\n' >&2
  exit 1
fi

# The pid is in the dir name so `vm-run.sh stop` can tell an orphan from a run that is still alive:
# a scope has no main process (systemd.scope(5)), so killing a guest never removes this dir.
run="$vm_tmp/vm-shell-$$"
log=$(vm_log_path vm-shell)
# A probe finishes in seconds; a push run copies a host closure into the guest's store disk and
# installs it onto the drive, so it is minutes of work; only a person at the keyboard needs the
# longest backstop. The value is the ceiling for a guest that never shuts itself down, not a wait
# anyone sits through.
default_timeout=300
[ -n "$script" ] && default_timeout=120
[ -n "$push_host" ] && default_timeout=900
boot_timeout=${VM_SHELL_TIMEOUT:-$default_timeout}
store_mb=${VM_STORE_IMG_MB:-8192}
mkdir -p "$run/tmp/xchg" "$vm_tmp/logs"
# The closure reaches the guest as a packed store archive on a share rather than through its ssh
# daemon. The archive is packed into the run dir on every run and dies with it: no archive cached on
# this host may satisfy the guest, so a run proves the closure travels rather than that a leftover
# archive still decodes. The cost is paid every run (measured: 240s of wall time and 28 CPU-minutes
# of xz for methyl-test's closure).
push_cache="$run/tmp/push-cache"
[ -n "$push_host" ] && mkdir -p "$push_cache"
# The archive this harness used to keep in $vm_tmp is gone; delete it so no run can find it.
[ -d "$vm_tmp/push-cache" ] && rm -rf "$vm_tmp/push-cache"
# --boot boots from files the probe copies out of the installed drive, since a host cannot read a
# file out of a qcow2 without root.
[ -n "$boot_drive" ] && mkdir -p "$run/tmp/deploy-out"

# The store disk, recreated every run so nothing carries over. truncate allocates nothing on XFS and
# mkfs.ext4 defers the inode tables, so the image costs a few megabytes until the guest writes to it
# (measured here: truncate 0 bytes, mkfs 4.3 MB). Never dd or fallocate — those allocate up front.
# debugfs creates upper and work because a mount unit creates no directories and overlayfs refuses a
# missing upperdir, which would read as a boot failure rather than a harness bug.
store_img="$run/tmp/rw-store.img"
truncate -s "${store_mb}M" "$store_img"
mkfs.ext4 -qF "$store_img"
printf 'mkdir /upper\nmkdir /work\n' | debugfs -w "$store_img" >/dev/null
# A run costs a store image plus a blank drive, and the log lives in $vm_tmp/logs, so dropping the
# run dir on exit loses nothing the report needs.
trap 'vm_kill_all; rm -rf "$run"' EXIT
trap 'vm_abort' INT TERM
(vm_watch_harness "$$" "$run") &

# The repo the guest installs from, without git history: the guest only ever reads the working
# tree. The trailing /. copies the contents — `cp -a dir existing-dir` nests the directory inside
# it, which is how a mounted share ends up with nothing at its top level.
cp -a "$repo/." "$run/tmp/xchg"
rm -rf "$run/tmp/xchg/.git"

{
  printf 'run=%s\n' "$run"
  printf 'caps: MemoryMax=1300M MemorySwapMax=0 timeout=%ss\n' "$boot_timeout"
  printf 'kvm=%s\n' "$(ls -l /dev/kvm)"
  printf 'store_img=%s apparent=%sM allocated=%sM\n' "$store_img" "$store_mb" "$(du -m "$store_img" | cut -f1)"
} >"$log"

# The closure is built here, in its own scope, before the guest boots: a flake eval inside a 1GB guest
# is exactly the thing that overflows RAM, which is why install.sh takes INSTALL_SYSTEM at all. It
# reaches the guest as the packed nars of the closure being installed, so the guest never reads this
# host's live /nix/store — which matters because it has autologin root and no password.
if [ -n "$push_host" ]; then
  push_system=$(vm_scope "vm-push-$$" 1200M bash -c \
    "cd $repo && nix build --no-link --print-out-paths .#nixosConfigurations.$push_host.config.system.build.toplevel" 2>>"$log") || {
    printf 'vm-shell.sh: no closure for host %s — the build failed (see %s)\n' "$push_host" "$log" >&2
    exit 1
  }
  printf '%s\n' "$push_system" >"$run/tmp/xchg/push-system"
  printf 'push=%s\n' "$push_system" >>"$log"
  # Packing is the slow half of the handover, and it is paid every run: the archive is this run's,
  # so nothing a previous run packed can stand in for it.
  rc=0
  start=$SECONDS
  nix copy --no-check-sigs --to "file:$push_cache" "$push_system" >>"$log" 2>&1 || rc=$?
  printf 'push_cache=new\n' >>"$log"
  printf 'push_rc=%s secs=%s\n' "$rc" "$((SECONDS - start))" >>"$log"
  if [ "$rc" -ne 0 ]; then
    printf 'vm-shell.sh: the closure could not be packed for the guest (%s)\n' "$push_system" >&2
    printf 'log=%s\n' "$log"
    exit 1
  fi
  # The checked-in recipe carries UUIDs recorded from the real host, and a UUID names a filesystem
  # that already exists — mkfs is never given one. A blank drive gets a fresh layout, so the run's
  # copy of the recipe drops them; the host's own file is untouched and install.sh records new ones.
  recipe="hosts/$push_host/terraform.json"
  [ -f "$recipe" ] && jq 'del(.partitions[].uuid)' "$recipe" >"$run/tmp/xchg/$recipe"
  printf 'push_recipe=%s uuids=%s\n' "$recipe" "$([ -f "$recipe" ] && echo stripped || echo none)" >>"$log"
fi

# ssh is on in the guest, so this run needs a key and a port. The guest authorises whatever this
# user already has in ~/.ssh/authorized_keys, so a second terminal is `ssh -p <port> vm@127.0.0.1`
# with your normal private key. Root is a special user in NixOS, so its authorized_keys lands
# outside /root and ssh goes to a normal user instead. With no authorized_keys file we fall back to
# a per-run keypair. No password is ever typed or passed in argv.
#
# The keys go into the override module as literals, not through builtins.readFile of a per-run path:
# readFile embeds the run directory, so every run's module is a different derivation and pays a
# fresh eval and build (measured here: 14s where the cached eval answers in 3s). Lines containing a
# quote or a backslash are skipped rather than escaped, since ssh keys are base64 plus a comment.
sshkey=""
keys_src="$HOME/.ssh/authorized_keys"
keys_list=""
if [ -s "$keys_src" ]; then
  # A quote or a backslash would need Nix escaping; ssh keys are base64 plus a comment, so a line
  # carrying one is dropped rather than escaped.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    keys_list="$keys_list\"$line\" "
  done < <(grep -v '["\\]' "$keys_src")
else
  sshkey="$run/host_key"
  ssh-keygen -t ed25519 -N '' -q -f "$sshkey"
  keys_src="$sshkey.pub"
  keys_list="\"$(cat "$keys_src")\""
  printf 'ssh: no ~/.ssh/authorized_keys, using a per-run keypair\n' >>"$log"
fi
port=""
# Loopback by default: the guest is scratch (autologin root, tmpfs root, blank drive), so publishing
# its ssh port on every interface is a person's choice, not the harness's default.
bind=${VM_SHELL_BIND:-127.0.0.1}
for candidate in 2222 2223 2224 2225 2226 2227; do
  [ -z "$(ss -ltnH "sport = :$candidate" 2>/dev/null)" ] && {
    port=$candidate
    break
  }
done
if [ -z "$port" ]; then
  printf 'vm-shell.sh: no free port to forward ssh on\n' >&2
  exit 1
fi

# Per-run config the checked-in guest does not carry: the authorized keys, the forwarded port, and
# the store disk. The store disk is a drive appended to the module's own list, so the guest's
# read-only store image (its own $TMPDIR/store.img) and the blank target drive keep their names:
# /dev/vda, /dev/vdb, then this at /dev/vdc.
override="$run/override.nix"
{
  printf '{ lib,\n  ...\n}:\n{\n'
  printf '  users.users.vm = {\n    isNormalUser = true;\n    openssh.authorizedKeys.keys = [ %s ];\n  };\n' "$keys_list"
  printf '  virtualisation.forwardPorts = [ { proto = "tcp"; host.address = "%s"; host.port = %s; guest.port = 22; } ];\n' "$bind" "$port"
  # shellcheck disable=SC2016  # the $ is Nix string text the generated boot script expands, not a shell expansion here
  # A plain list merges by concatenation (types.listOf's merge), so this appends after the module's
  # own drives rather than replacing them.
  printf '  virtualisation.qemu.drives = [ { file = "$TMPDIR/rw-store.img"; driveExtraOpts.format = "raw"; } ];\n'
  # The writable store moves onto that disk instead of a tmpfs, so registering a host closure costs
  # disk rather than the guest's RAM.
  printf '  virtualisation.writableStoreUseTmpfs = false;\n'
  printf '  virtualisation.fileSystems."/nix/.rw-store" = { device = "/dev/vdc"; fsType = "ext4"; neededForBoot = true; };\n'
  if [ -n "$push_host" ]; then
    # A host closure has to fit on the drive it is installed onto, and the 4 GB default does not.
    printf '  virtualisation.emptyDiskImages = lib.mkForce [ %s ];\n' "${VM_PUSH_DRIVE_MB:-10240}"
    # The rebuilt closure still comes over ssh — it is new every run, so it can never be packed and
    # cached — and the daemon refuses unsigned paths unless the user behind the ssh session is a
    # trusted user (nixos/modules/services/misc/nix-ssh-serve.nix does the same for its own nix-ssh
    # user).
    printf '  nix.settings.trusted-users = [ "root" "vm" ];\n'
    # The initial closure comes as a store archive instead: the guest reads packed nars off this
    # share and registers them itself. The source is an absolute host path, not a $TMPDIR literal,
    # because the archive is kept between runs.
    printf '  virtualisation.sharedDirectories.push = { source = "%s"; target = "/push-cache"; securityModel = "none"; };\n' "$push_cache"
    if [ -n "$boot_drive" ]; then
      # The probe copies kernel/initrd out of the installed drive here; /mnt is the install
      # target, so a share under it would be shadowed by the mount.
      # The literal must stay literal: Nix passes it to the VM runner, whose shell expands $TMPDIR
      # against the run directory it boots in (vm_boot sets TMPDIR=$run_dir USE_TMPDIR=1), so the
      # guest's /deploy-out lands in exactly $run/tmp/deploy-out, which is where the host reads it.
      # shellcheck disable=SC2016
      printf '  virtualisation.sharedDirectories.deploy = { source = "$TMPDIR/deploy-out"; target = "/deploy-out"; };
'
    fi
  fi
  printf '}\n'
} >"$override"

vm_build ./tests/vm-shell.nix "$run/guest" "$override" >>"$log" 2>&1

fifo="$run/console.fifo"
mkfifo "$fifo"
# tee, not a plain redirect: the console is the interface, so the person who ran this sees it while
# the host still keeps the transcript.
vm_boot "$run/guest" "$run/tmp" "$log" "$boot_timeout" "$fifo" tee &
boot=$!
# The write end opens only after the boot is launched: qemu opens the fifo for reading in the
# background, and an O_WRONLY open of a fifo blocks until a reader exists.
vm_console_open "$fifo"

# RAM is sampled while the guest is up, from the host's own cgroup (the guest's /proc reports its
# own namespace limit).
vm_free_peak "$boot_timeout" qemu-system "$boot" >>"$log" 2>&1 &
peak=$!

# Wait for the autologin shell before anything is typed: serial-getty prints its prompt before the
# shell behind it exists, so lines typed at the first prompt are eaten by login and the guest then
# sits idle at a prompt — which looks exactly like a hung run.
vm_wait_for "$log" "root@" 90 || {
  printf 'vm-shell.sh: no autologin prompt in the console\n' >>"$log"
  exit 1
}

# The guest's own boot banner is the ready signal on the serial console — sshd's line goes to the
# journal, which never reaches ttyS0, and typing before the banner lands in a login getty that
# swallows it. So: wait for the banner, then prove the forwarded port answers from this host. One
# attempt plus one retry covers sshd finishing after the banner; blind retries are what made a
# healthy guest cost a minute.
ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
[ -n "$sshkey" ] && ssh_opts="$ssh_opts -i $sshkey"
ssh_base="ssh -p $port $ssh_opts"
ssh_result=""
if vm_wait_for "$log" "Welcome to NixOS" 60; then
  if $ssh_base -o ConnectTimeout=5 vm@127.0.0.1 'echo SSH_OK' >"$run/ssh.out" 2>&1 ||
    {
      sleep 2
      $ssh_base -o ConnectTimeout=5 vm@127.0.0.1 'echo SSH_OK' >>"$run/ssh.out" 2>&1
    }; then
    ssh_result=ok
  fi
fi
printf 'ssh=%s\n' "${ssh_result:-failed}" | tee -a "$log"
# qemu's user-mode networking is a NAT emulator inside qemu: 10.0.2.15 exists only in the guest, so
# the host has no route to it and ssh there never opens a session. The forwarded port is the way in,
# and it is printed once ssh answers, since a person cannot guess which port this run picked.
if [ "$ssh_result" = ok ]; then
  # With the port published on every interface, the address worth naming is this host's LAN address.
  reach=$bind
  [ "$bind" = "0.0.0.0" ] &&
    reach=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  printf 'ssh: %s vm@%s — 10.0.2.15 is qemu internal NAT, unreachable from this host\n' "$ssh_base" "${reach:-this host}"
else
  tail -c 200 "$run/ssh.out" >>"$log"
  # Only --boot needs ssh: it is the run whose rebuilt closure is pushed back, and a rebuilt closure
  # is new every run, so it can never be packed into the archive the other push reads from.
  if [ -n "$boot_drive" ]; then
    printf 'vm-shell.sh: --boot needs the forwarded ssh port to answer\n' >&2
    printf 'log=%s\n' "$log"
    vm_kill_scope "vm-boot-$$"
    exit 1
  fi
fi

if [ -n "$script" ]; then
  printf 'bash /repo/%s\n' "${script#"$repo/"}" >&9
  # The terraform stage records the identities it formatted into the repo copy in the share, and the
  # closure installed onto the drive has to be the one rebuilt from that recipe — its fstab names the
  # uuids this drive carries, or the drive's boot times out on /dev/disk/by-uuid. Rebuild here and
  # push it back; the probe waits on rebuilt-system, so this runs while the guest is still up.
  if [ -n "$boot_drive" ]; then
    (
      for _ in $(seq 120); do
        [ -e "$run/tmp/deploy-out/rebuild-request" ] && break
        sleep 1
      done
      [ -e "$run/tmp/deploy-out/rebuild-request" ] || exit 0
      rebuilt=$(vm_scope "vm-rebuild-$$" 1200M bash -c \
        "cd $run/tmp/xchg && nix build --no-link --print-out-paths .#nixosConfigurations.$push_host.config.system.build.toplevel" 2>>"$log") || {
        printf 'rebuild failed\n' >"$run/tmp/deploy-out/rebuild-failed"
        exit 0
      }
      NIX_SSHOPTS="$ssh_opts" nix copy --no-check-sigs --to "ssh://vm@127.0.0.1:$port" "$rebuilt" \
        >>"$log" 2>&1 || {
        printf 'push of the rebuilt closure failed\n' >"$run/tmp/deploy-out/rebuild-failed"
        exit 0
      }
      printf '%s\n' "$rebuilt" >"$run/tmp/deploy-out/rebuilt-system.new"
      mv "$run/tmp/deploy-out/rebuilt-system.new" "$run/tmp/deploy-out/rebuilt-system"
      printf 'rebuild=%s\n' "$rebuilt" >>"$log"
    ) &
  fi
  exec 9>&-
  # A probe that reports a failure exits its shell, so the getty respawns and the console goes idle
  # — that idle is what a failing run looks like from the outside. Ending here, on the guest's own
  # marker, is the difference between a report and a hang. poweroff cannot be typed instead: after
  # fail() exits there is no shell, so it would be read as a username at the login prompt.
  if vm_wait_for "$log" "SHELL DONE\|SHELL FAIL" "$boot_timeout"; then
    if grep -aq 'SHELL FAIL' "$log"; then
      vm_kill_scope "vm-boot-$$"
      wait "$boot" || true
      printf 'probe failed\n' >>"$log"
      printf 'log=%s\n' "$log"
      exit 1
    fi
  fi
else
  # Forward the terminal until qemu closes the console; a write into a closed fifo dies with SIGPIPE.
  cat >&9
fi
exec 9>&-
vm_end_boot "vm-boot-$$" "$peak" "$boot"

# Boot the drive the probe installed onto. The guest is shut down first: its qcow2 holds the installed
# system, and the second qemu boots the kernel and initrd the probe copied out of it (D7).
if [ -n "$boot_drive" ]; then
  qemu=$(grep -ao '/nix/store/[^ ]*-qemu[^ ]*/bin/qemu-system-x86_64' "$run"/guest/bin/run-*-vm | head -1)
  [ -n "$qemu" ] || {
    printf 'vm-shell.sh: the built VM script names no qemu binary\n' >&2
    exit 1
  }
  out="$run/tmp/deploy-out"
  for f in kernel initrd append.txt; do
    if [ ! -s "$out/$f" ]; then
      printf 'vm-shell.sh: the probe left no %s in %s\n' "$f" "$out" >&2
      exit 1
    fi
  done
  printf 'disk_boot=%s append=%s\n' "$run/tmp/empty0.qcow2" "$(cat "$out/append.txt")" >>"$log"

  # Multi-user is proven by the installed system's own login prompt, not by a systemd line: plymouth
  # swallows "Reached target Multi-User System" on this console, and serial-getty — the prompt — only
  # starts once multi-user is reached. A drive that fails to mount its uuids drops to emergency mode
  # instead, which prints no login prompt, so this marker separates the two. The offset is recorded
  # here because the deploy guest wrote its own prompt into the same log earlier.
  boot_start=$(wc -c <"$log")
  vm_boot_disk "$out/kernel" "$out/initrd" "$(cat "$out/append.txt")" "$run/tmp/empty0.qcow2" "$log" \
    "${VM_BOOT_TIMEOUT:-300}" "$qemu" &
  disk=$!
  # Sampled in its own background job, so the pid lands in this shell: assigning $(...) inside a
  # backgrounded pipeline leaves peak_disk empty here, and the wait below waits for nothing.
  vm_free_peak "${VM_BOOT_TIMEOUT:-300}" qemu-system "$disk" | tee -a "$log" &
  peak_disk=$!

  if vm_wait_for "$log" 'login:' "${VM_BOOT_TIMEOUT:-300}" "$boot_start"; then
    printf 'BOOT OK: installed generation reached its login prompt\n' >>"$log"
  else
    printf 'installed drive never reached a login prompt\n' >>"$log"
    vm_kill_scope "vm-disk-boot-$$"
    printf 'log=%s\n' "$log"
    exit 1
  fi
  # Nothing is typed into this boot: the drive's root stays locked until postdeploy runs on the real
  # host, and a serial login stalls at Password: on the installed config. The scope is ended here
  # rather than letting VM_BOOT_TIMEOUT run out on a prompt that is already proof enough.
  vm_end_boot "vm-disk-boot-$$" "$peak_disk" "$disk"
fi

printf 'log=%s\n' "$log"
