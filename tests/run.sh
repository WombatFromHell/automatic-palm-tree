#!/usr/bin/env bash
# Eval-only test gate. Green suites must print "OK <suite>"; red guards in
# tests/red/ must throw, with the message named in their first line
# (`# expect: <substring>`). Nothing here builds a real package: the single exception is
# tests/appdir.nix, which builds a synthetic AppDir fixture and downloads nothing.
#
# Every eval goes through tests/nix-eval.sh, which caps it in a transient systemd scope
# (override with TEST_MEMORY_MAX_MB) so a suite that balloons is killed here instead of
# swapping the machine.
set -u
cd "$(dirname "$0")/.."

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

for suite in tests/*.nix; do
  case "$suite" in
    tests/support.nix | tests/configs.nix | tests/appdir.nix) continue ;;
  esac
  if out=$(TEST_SCOPE_NAME="$(basename "$suite" .nix)" tests/nix-eval.sh "$mem" -- nix eval --impure --file "$suite" 2>&1); then
    split_peak "$out"
    echo "ok   $suite  $body  $peak"
  else
    split_peak "$out"
    echo "FAIL $suite  $peak"
    echo "$body" | tail -20
    fail=1
  fi
done

# What a derivation puts in its $out is not an evaluated value, so tests/appdir.nix re-runs
# features/hm-ghostty/_package.nix's real installPhase against a synthetic AppDir and the gate
# reads the build's exit status. src is a placeholder, so no AppImage is ever fetched; this is
# the only build the gate performs (~8s on a warm store).
if out=$(TEST_SCOPE_NAME=appdir tests/nix-eval.sh "$mem" -- nix build --no-link --quiet -f tests/appdir.nix 2>&1); then
  split_peak "$out"
  echo "ok   tests/appdir.nix [fixture build]  $peak"
else
  split_peak "$out"
  echo "FAIL tests/appdir.nix [fixture build]  $peak"
  echo "$body" | tail -20
  fail=1
fi

# tests/configs.nix evaluates one host per process (see its header): forcing three hosts in
# one eval needs ~4GB, which is over the cap.
for host in methyl methyl-nixos propyl; do
  if out=$(TEST_HOST="$host" TEST_SCOPE_NAME="configs-$host" tests/nix-eval.sh "$mem" -- nix eval --impure --file tests/configs.nix 2>&1); then
    split_peak "$out"
    echo "ok   tests/configs.nix [$host]  $body  $peak"
  else
    split_peak "$out"
    echo "FAIL tests/configs.nix [$host]  $peak"
    echo "$body" | tail -20
    fail=1
  fi
done

# The boot path must be a rebuild that installs the bootloader. nixos-rebuild-ng sets
# NIXOS_INSTALL_BOOTLOADER itself and runs the activation under `env -i`, so an `env`
# prefix never reaches it — only the flag does.
if ! grep -q -- '--install-bootloader' bootstrap.sh || grep -q 'env NIXOS_INSTALL_BOOTLOADER' bootstrap.sh
then
  echo "FAIL bootstrap.sh must boot with --install-bootloader and no env NIXOS_INSTALL_BOOTLOADER"
  fail=1
fi

# bootstrap.sh's rebuild is mocked, never run: stubs on PATH stand in for `sudo` and
# `nixos-rebuild`, so nothing here takes root, activates, or builds. The stub reports its own
# cgroup, which proves the memory scope is really wrapping the rebuild rather than being grepped
# for. XDG_RUNTIME_DIR pointing at a bus-less directory takes the unscoped fallback branch.
mock=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-mock.XXXXXX")
cat > "$mock/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
cat > "$mock/nixos-rebuild" <<'STUB'
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
if printf '%s' "$scoped" | grep -q 'stub: nixos-rebuild boot' \
  && printf '%s' "$scoped" | grep -q -- '--install-bootloader' \
  && printf '%s' "$scoped" | grep -q -- '--option extra-substituters' \
  && printf '%s' "$scoped" | grep -q 'flakeroot-rebuild' \
  && printf '%s' "$unscoped" | grep -q 'stub: nixos-rebuild boot' \
  && ! printf '%s' "$unscoped" | grep -q 'flakeroot-rebuild'
then
  echo "ok   bootstrap.sh [mocked rebuild: scope wrap + no-bus fallback]"
else
  echo "FAIL bootstrap.sh must rebuild in a memory scope and fall back when there is no user bus"
  echo "$scoped" | tail -8
  echo "$unscoped" | tail -8
  fail=1
fi

# bootstrap.sh behaviour is bash-level — which installer flags it picks, which switch command it
# picks, the flags it refuses, the trusted-user gate — so it is a bats suite against stubs, not an
# eval suite: ~0MB and ~1s. bats comes from the installed Nix profile, so the gate *skips* rather
# than fails when it is missing.
if command -v bats > /dev/null 2>&1; then
  if out=$(bats tests/bootstrap.bats 2>&1); then
    echo "ok   tests/bootstrap.bats [$(printf '%s\n' "$out" | grep -c '^ok') passed]"
  else
    echo "FAIL tests/bootstrap.bats"
    printf '%s\n' "$out" | grep -E '^not ok|^# ' | tail -20
    fail=1
  fi
else
  echo "skip tests/bootstrap.bats [bats not installed]"
fi

# The rebuild harness (rebuild-gate.sh) is how rebuild RAM gets measured, so its target
# discovery is checked here rather than by running a real build: discovery must name this
# flake's own NixOS toplevels and home activation packages, and a trivial plan must survive the
# scope cap. Nothing here evaluates a host configuration.
if ! bash -n rebuild-gate.sh; then
  echo "FAIL rebuild-gate.sh does not parse"
  fail=1
elif targets=$(bash rebuild-gate.sh -m list 2>/dev/null) \
  && printf '%s\n' "$targets" | grep -q '^\.#nixosConfigurations\.methyl\.config\.system\.build\.toplevel$' \
  && printf '%s\n' "$targets" | grep -q '^\.#homeConfigurations\.josh@methyl-bazzite\.activationPackage$' \
  && bash rebuild-gate.sh -m probe -c 1200 -t '(builtins.getFlake (toString ./.)).outputs.nixosConfigurations.methyl' \
       -e '.config.system.stateVersion' >/dev/null 2>&1 \
  && bash rebuild-gate.sh -m plan -t nixpkgs#hello >/dev/null 2>&1; then
  echo "ok   rebuild-gate.sh [discovery + spine probe + trivial plan]"
else
  echo "FAIL rebuild-gate.sh (parse, discovery, or trivial plan)"
  fail=1
fi

# Byte-parity between the two template expanders, which live in different runtimes:
# lib/updater.sh render_url (bash, at fetch time) and lib/pin-meta.nix releaseAsset
# (Nix, at eval time). Both must produce the same URL for every pin and system, or a
# pin update drifts silently and only shows up as a build-time hash mismatch.
# One eval lists every pin and system; the bash side expands the same list. Per-pin
# evals cost ~2.9s each (nixpkgs re-imported), which was most of the gate's runtime.
par=0
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

for guard in tests/red/*.nix; do
  want=$(head -n 1 "$guard" | sed 's/^# expect: //')
  if out=$(TEST_SCOPE_NAME="red-$(basename "$guard" .nix)" tests/nix-eval.sh "$mem" -- nix eval --impure --file "$guard" 2>&1); then
    echo "FAIL $guard  expected a throw mentioning \"$want\""
    fail=1
  elif case "$out" in *"$want"*) true ;; *) false ;; esac; then
    split_peak "$out"
    echo "ok   $guard  $peak"
  else
    echo "FAIL $guard  expected \"$want\""
    echo "$out" | tail -8
    fail=1
  fi
done

exit "$fail"
