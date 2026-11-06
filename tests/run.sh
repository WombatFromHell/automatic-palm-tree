#!/usr/bin/env bash
# Eval-only test gate. Green suites must print "OK <suite>"; the value-tier assertions run as
# nix-unit test attributes (tests/suite.nix), where a must-throw check is an `expectedError`
# attribute rather than a separate file. Nothing here builds a real package: the exceptions are
# tests/appdir.nix, which builds a synthetic AppDir fixture and downloads nothing,
# tests/shellwrap.nix, which builds the three writeShellApplication wrappers so nixpkgs' shellcheck
# runs on the text that ships, and tests/yazi-install.nix, which unpacks the pinned yazi sources
# and re-runs their postInstall — nothing compiles and no crate is fetched; the archive (~15 MB)
# plus installShellFiles and imagemagick are what it pulls.
#
# Every eval goes through tests/nix-eval.sh, which caps it in a transient systemd scope
# (override with TEST_MEMORY_MAX_MB) so a suite that balloons is killed here instead of
# swapping the machine.
set -u
cd "$(dirname "$0")/.." || exit

# Determinate enables flakes in /etc/nix/nix.conf; upstream Nix has no global config, so the gate
# carries the experimental features itself rather than relying on whatever the host installed.
export NIX_CONFIG="experimental-features = nix-command flakes"

# Each eval is capped at this much memory (tests/nix-eval.sh). One host's config costs ~1.4GB
# of anonymous memory, hence the per-host configs run below.
mem="${TEST_MEMORY_MAX_MB:-1792}"

# nix writes fetcher locks under $XDG_CACHE_HOME, which is read-only in some
# sandboxes; fall back to a scratch cache dir rather than failing every suite.
cache="${XDG_CACHE_HOME:-$HOME/.cache}"
if ! mkdir -p "$cache" 2>/dev/null || [ ! -w "$cache" ]; then
  cache="${TMPDIR:-/tmp}/nix-eval-cache"
  mkdir -p "$cache"
fi
export XDG_CACHE_HOME="$cache"

fail=0

# Shell that ships without writeShellApplication is never linted: nixpkgs' checkPhase only sees the
# text it wraps. These are shipped as-is, so the gate lints them itself (~0MB, ~1s, no nix).
# shortcut: inline text passed to writeShellScriptBin (features/hm-gpg/home.nix's pinentry-fallback)
# is not covered here -- upgrading means routing that text through a wrapper the gate builds.
lint_files=(bootstrap.sh update-all.sh lib/updater.sh lib/cache-check.sh lib/style.sh install.sh
  terraform.sh lib/confirm.sh
  features/hm-gpg/pinentry-tmux.sh features/hm-gpg/pinentry-zellij.sh
  features/hm-nasmount/nasmount-sshfs.sh)
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "skip shipped shell lint [shellcheck not installed]"
elif out=$(shellcheck -f gcc "${lint_files[@]}" 2>&1); then
  echo "ok   shipped shell lint  ${#lint_files[@]} files"
else
  echo "FAIL shipped shell lint"
  printf '%s\n' "$out" | tail -20
  fail=1
fi

# tests/nix-eval.sh reports the scope's highest memory on stderr. Keep the suite's own output on
# one line and carry the peak alongside it, so the cap is auditable: a suite that balloons shows
# up here instead of only in a separate measurement.
peak=""
body=""
split_peak() {
  body=$(printf '%s\n' "$1" | grep -v '^peak=')
  peak=$(printf '%s\n' "$1" | grep '^peak=' | tail -n 1)
  [ -n "$peak" ] || peak="peak=n/a"
}

# Every suite goes through the same gate: run it in the memory scope, print the verdict and the
# peak on one line, and dump the tail of the output when it fails.
gate() {
  local label="$1" scope="$2"
  shift 2
  local out
  if out=$(TEST_SCOPE_NAME="$scope" tests/nix-eval.sh "$mem" -- "$@" 2>&1); then
    split_peak "$out"
    echo "ok   $label  $body  $peak"
  else
    split_peak "$out"
    echo "FAIL $label  $peak"
    printf '%s\n' "$body" | tail -20
    fail=1
  fi
}

# `nix develop` is where the pin updaters run (features/*/update.sh -> lib/updater.sh), so the
# tools they need must resolve from the devShell, not from whatever the host installed. terraform.sh
# is the same claim for the disk tools: the installer ISO is not this devShell, so the gate is where
# "the script only uses tools we ship" gets checked.
gate "nix develop resolves the updater and disk tools" devshell nix develop --command \
  bash -c 'command -v curl jq nix bats shellcheck shfmt sfdisk blkid mkfs.vfat mkfs.ext4 mcopy sgdisk >/dev/null'

# The value-tier assertions run as nix-unit test attributes in one process (tests/suite.nix), so a
# failing attribute prints its own diff and the rest keep running instead of the whole suite
# throwing at the first failure. nix-unit comes from the devShell, so this is skipped when absent,
# exactly like the bats tier. --impure because tests/support.nix reads the flake itself.
if nix develop --command sh -c 'command -v nix-unit >/dev/null 2>&1'; then
  gate "tests/suite.nix" nix-unit nix develop --command nix-unit --impure tests/suite.nix
else
  echo "skip tests/suite.nix [nix-unit not in the devShell]"
fi

# apps.cache-check is a real `nix run` of the app, so it is capped like the rest: forcing one
# host config is the eval it does (~1.6GB peak, measured here), which the stub bats loop below
# would run unmeasured.
gate "tests/cache-check.bats" cache-check bats tests/cache-check.bats

# Eval-only suites, listed explicitly. The suites whose assertions are pure values now run as
# nix-unit attributes below, so they are not in this list. configs.nix is not here either: it
# evaluates one host per process (see its header). outputs.nix forces the flake outputs;
# home.nix/mounts.nix/wrap.nix force a host config. support.nix is a fixture library, and
# appdir/brave-layout/shellwrap/yazi-install build (below).
# A failing suite throws with every failing check named; nix eval's exit status is the verdict.
eval_suites=(tests/home.nix tests/mounts.nix tests/outputs.nix tests/wrap.nix)
for suite in "${eval_suites[@]}"; do
  gate "$suite" "$(basename "$suite" .nix)" nix eval --impure --file "$suite"
done

# What a derivation puts in its $out is not an evaluated value, so tests/appdir.nix re-runs
# features/hm-ghostty/_package.nix's real installPhase against a synthetic AppDir and the gate
# reads the build's exit status. src is a placeholder, so no AppImage is ever fetched; this is
# the only build the gate performs (~8s on a warm store).
gate "tests/appdir.nix [fixture build]" appdir nix build --no-link --quiet -f tests/appdir.nix

# The same build-tier logic for hm-brave's store layout: tests/brave-layout.nix re-runs the
# derivation's real installPhase over a synthetic rpm payload, where a copy of a store ELF stands
# in for the patched binary (patchelf needs real ELF bytes). bin/ symlinks, the desktop-entry Exec
# rewrite and the icon placement are checked against the tree that ships (~5s on a warm store,
# and the rpm is never fetched).
gate "tests/brave-layout.nix [rpm fixture build]" brave-layout nix build --no-link --quiet -f tests/brave-layout.nix

# The same build-tier logic for the shipped shell wrappers: writeShellApplication shellchecks the
# text it wraps, so the thing that ships is the thing that is linted (~4s on a warm store, and no
# upstream fetch -- xilo's store path is a placeholder in tests/shellwrap.nix).
gate "tests/shellwrap.nix [wrapper build + shellcheck]" shellwrap nix build --no-link --quiet -f tests/shellwrap.nix

# The same build-tier logic for the pinned yazi build: tests/yazi-install.nix unpacks the real
# pinned sources and re-runs features/hm-yazi/_package.nix's real postInstall, so the completion
# names, man pages, desktop entry and resized logos are checked against the revision actually
# pinned rather than a tree the test drew (~10s on a warm store, ~15 MB of sources once).
gate "tests/yazi-install.nix [postInstall fixture]" yazi-install nix build --no-link --quiet -f tests/yazi-install.nix

# tests/configs.nix evaluates one host per process (see its header): forcing three hosts in
# one eval needs ~4GB, which is over the cap.
for host in methyl methyl-nixos propyl; do
  TEST_HOST="$host" gate "tests/configs.nix [$host]" "configs-$host" nix eval --impure --file tests/configs.nix
done

# The boot path must be a rebuild that installs the bootloader. nixos-rebuild-ng sets
# NIXOS_INSTALL_BOOTLOADER itself and runs the activation under `env -i`, so an `env`
# prefix never reaches it — only the flag does.
if ! grep -q -- '--install-bootloader' bootstrap.sh || grep -q 'env NIXOS_INSTALL_BOOTLOADER' bootstrap.sh; then
  echo "FAIL bootstrap.sh must boot with --install-bootloader and no env NIXOS_INSTALL_BOOTLOADER"
  fail=1
fi

# bootstrap.sh's rebuild is mocked, never run: stubs on PATH stand in for `sudo` and
# `nixos-rebuild`, so nothing here takes root, activates, or builds. The stub reports its own
# cgroup, which proves the memory scope is really wrapping the rebuild rather than being grepped
# for. XDG_RUNTIME_DIR pointing at a bus-less directory takes the unscoped fallback branch.
mock=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-mock.XXXXXX")
cat >"$mock/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
cat >"$mock/nixos-rebuild" <<'STUB'
#!/usr/bin/env bash
echo "stub: nixos-rebuild $*"
# The cgroup is the observation that the scope wrap really happened, not a grep for it.
printf 'cgroup=%s\n' "$(cat /proc/self/cgroup)"
STUB
mkdir "$mock/no-bus"
chmod +x "$mock/sudo" "$mock/nixos-rebuild"
scoped=$(PATH="$mock:$PATH" TEST_SCOPE_NAME=bootstrap-scoped tests/nix-eval.sh 600 -- bash bootstrap.sh methyl 2>&1)
unscoped=$(PATH="$mock:$PATH" TEST_SCOPE_NAME=bootstrap-fallback tests/nix-eval.sh 600 -- env XDG_RUNTIME_DIR="$mock/no-bus" bash bootstrap.sh methyl 2>&1)
rm -rf "$mock"
# The rebuild's own argv (--install-bootloader, the cache options) is asserted in
# tests/bootstrap.bats; what only the gate can see is the scope: the stub reports its cgroup, which
# names the scope unit when the wrap happened and does not when there is no user bus.
if printf '%s' "$scoped" | grep -q 'stub: nixos-rebuild boot' &&
  printf '%s' "$scoped" | grep -q 'cgroup=.*flakeroot-rebuild' &&
  printf '%s' "$unscoped" | grep -q 'stub: nixos-rebuild boot' &&
  ! printf '%s' "$unscoped" | grep -q 'flakeroot-rebuild'; then
  echo "ok   bootstrap.sh [mocked rebuild: scope wrap + no-bus fallback]"
else
  echo "FAIL bootstrap.sh must rebuild in a memory scope and fall back when there is no user bus"
  echo "$scoped" | tail -8
  echo "$unscoped" | tail -8
  fail=1
fi

# bootstrap.sh and build-harness.sh behaviour is bash-level — which installer flags bootstrap
# picks, which switch command it picks, the trusted-user gate; and which command each nix client
# maps to, what the telemetry line reports, what the harness refuses — so both are bats suites
# against PATH stubs, not eval suites: ~0MB and ~1s. njust's scope x mode argv, its local/remote
# activation split and its xilo push rules are the same kind of thing, so tests/njust.bats joins
# them. credsctl's record contract (one secret per file, extension picks the backend, records are
# immutable) is argv and exit codes too, so tests/creds.bats joins them; its two real-tier tests
# run the actual systemd-creds and age and skip when either is absent. sopsctl's sops plumbing
# (key by command, json types on encrypt, field edits re-encrypted to the record's own recipients)
# is the same kind of thing, so tests/sopsctl.bats joins them and its real tier runs actual sops.
# xilo-wrapped is the same shape: which records it asks credsctl for, in what order, and that the
# CLI's own argv and exit status survive, so tests/xilo.bats joins them.
# install.sh is staged destruction: which step asks for a yes, what a scripted run refuses, and that
# prepare leaves the partition table byte-identical, so tests/install.bats joins them on stubs.
# terraform.sh is the shared-drive half, so tests/terraform.bats runs it against real filesystems in
# files: a blank partition gets really formatted, and a partition another OS owns must come back
# byte-identical. No root, no loop device, no derivation (ADR-b77ec913151f).
if ! command -v bats >/dev/null 2>&1; then
  echo "skip bats suites [bats not installed]"
else
  for suite in tests/bootstrap.bats tests/build-harness.bats tests/njust.bats tests/creds.bats \
    tests/sopsctl.bats tests/xilo.bats tests/updater.bats tests/install.bats; do
    if out=$(bats "$suite" 2>&1); then
      echo "ok   $suite [$(printf '%s\n' "$out" | grep -c '^ok') passed]"
    else
      echo "FAIL $suite"
      printf '%s\n' "$out" | grep -E '^not ok|^# ' | tail -20
      fail=1
    fi
  done
fi

# terraform.bats is not stub-driven: it runs real mkfs, blkid, mtools and sgdisk on sparse files,
# so it runs in the devShell, which is the environment that carries those tools (ADR-b77ec913151f).
# Running it plainly would skip it on any machine without them, which is where the proof matters.
if command -v nix >/dev/null 2>&1 && command -v bats >/dev/null 2>&1; then
  if out=$(nix develop --command bats tests/terraform.bats 2>&1); then
    echo "ok   tests/terraform.bats [$(printf '%s\n' "$out" | grep -c '^ok') passed]"
  else
    echo "FAIL tests/terraform.bats"
    printf '%s\n' "$out" | grep -E '^not ok|^# ' | tail -20
    fail=1
  fi
else
  echo "skip tests/terraform.bats [nix or bats not installed]"
fi

# Byte-parity between the two template expanders, which live in different runtimes:
# lib/updater.sh render_url (bash, at fetch time) and lib/pin-meta.nix releaseAsset
# (Nix, at eval time). Both must produce the same URL for every pin and system, or a
# pin update drifts silently and only shows up as a build-time hash mismatch.
# One eval lists every pin and system; the bash side expands the same list. Per-pin
# evals cost ~2.9s each (nixpkgs re-imported), which was most of the gate's runtime.
par=0
# The single quotes are deliberate: `${f}` and the `./` paths must reach Nix unexpanded.
# shellcheck disable=SC2016
parout=$(TEST_SCOPE_NAME=parity tests/nix-eval.sh "$mem" -- nix eval --impure --raw --expr '
  let lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib;
      pinMeta = import ./lib/pin-meta.nix {inherit lib;};
      dirs = builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./features));
      line = f: let
        pin = builtins.fromJSON (builtins.readFile ./features/${f}/metadata.json);
      in
        lib.concatMapStringsSep "\n"
          (s: "${f}:${s}:${pin.version}:${(pinMeta.releaseAsset pin s).url}")
          (pinMeta.pinnedSystems pin);
  in
    lib.concatMapStringsSep "\n" line
      (lib.filter (f: builtins.pathExists ./features/${f}/metadata.json) dirs)
' 2>&1) || {
  echo "FAIL parity (nix eval)"
  par=1
}
# The eval result is a line-per-pin list; tests/nix-eval.sh's peak line is not part of it.
split_peak "$parout"
pins="$body"
while IFS=: read -r feature sys ver want; do
  [ -n "$feature" ] || continue
  got=$(
    # Every features/*/update.sh is a symlink to lib/updater.sh (pinned by tests/pins.nix), which
    # is shellchecked on its own. The path is a variable, so the directive tells shellcheck to
    # accept the source without following it; naming the target would only resolve relative to
    # wherever shellcheck happens to be invoked.
    # shellcheck source=/dev/null
    . "features/$feature/update.sh"
    render_url "$sys" "$ver"
  )
  if [ "$want" != "$got" ]; then
    echo "FAIL parity features/$feature $sys"
    echo "  nix:  $want"
    echo "  bash: $got"
    par=1
  fi
done <<<"$pins"
if [ "$par" = 0 ]; then
  echo "ok   expander parity  $peak"
else
  fail=1
fi

exit "$fail"
