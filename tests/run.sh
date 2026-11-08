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

# missing <label> <reason> — a tier whose tool is absent is a skip locally, but in CI it is lost
# coverage: the gate that runs in CI must fail rather than print ok for suites that never ran.
missing() {
  if [ -n "${CI:-}" ]; then
    echo "FAIL $1 [$2]"
    fail=1
  else
    echo "skip $1 [$2]"
  fi
}

# Assertion floors (tests/floors.sh against tests/suite-ledger.txt): a suite that stops proving
# something is a source change, so this guard only greps -- ~0MB, no eval. Its counts are reused on
# the bats verdict lines below, so an "ok" always says how much was proven.
if floors=$(tests/floors.sh 2>&1); then
  echo "ok   assertion floors [$(awk '{a[$2]+=$3} END{printf "%d assertions, %d checks, %d attrs", a["assert"], a["checks"], a["attrs"]}' <<<"$floors")]"
else
  echo "FAIL assertion floors"
  printf '%s\n' "$floors" | grep '^FAIL' | tail -20
  fail=1
fi

# Shell that ships without writeShellApplication is never linted: nixpkgs' checkPhase only sees the
# text it wraps. These are shipped as-is, so the gate lints them itself (~0MB, ~1s, no nix).
# shortcut: inline text passed to writeShellScriptBin (features/hm-gpg/home.nix's pinentry-fallback)
# is not covered here -- upgrading means routing that text through a wrapper the gate builds.
lint_files=(bootstrap.sh update-all.sh lib/updater.sh lib/cache-check.sh lib/style.sh install.sh
  terraform.sh lib/confirm.sh
  features/hm-gpg/pinentry-tmux.sh features/hm-gpg/pinentry-zellij.sh
  features/hm-nasmount/nasmount-sshfs.sh)
wave=$(mktemp -d "${TMPDIR:-/tmp}/gate-wave.XXXXXX")

# The lint shares nothing with the eval wave, so it runs inside the wave window instead of taking a
# serial stretch of the script at the top or bottom. A job prints its own verdict line; `collect`
# below prints it in the order the caller listed it.
lint=run
command -v shellcheck >/dev/null 2>&1 || lint=skip
if [ "$lint" = run ]; then
  (
    { shellcheck -f gcc "${lint_files[@]}" 2>&1 && echo "ok   shipped shell lint  ${#lint_files[@]} files"; } >"$wave/lint" 2>&1
    printf '%s' "$?" >"$wave/lint.rc"
  ) &
fi

# collect <label> <out-file> — a background check that prints its own verdict line, so it needs no
# scope telemetry to interpret. Only the failure details are shown.
collect() {
  local label="$1" out="$2"
  if [ "$(cat "$out.rc")" = 0 ]; then
    cat "$out"
  else
    echo "FAIL $label"
    tail -20 "$out"
    fail=1
  fi
}

# bats_verdict <label> <tap-file> <assert-floor> [peak] — a bats TAP file becomes one verdict line
# carrying the count the ledger floors, and the failures that explain a red tier. Both tiers need
# exactly that, so they share it.
bats_verdict() {
  local label="$1" file="$2" asserts="$3" extra="${4:-}"
  if [ "$(cat "$file.rc")" = 0 ]; then
    echo "ok   $label [$(grep -c '^ok' "$file") passed, $asserts assertions]${extra:+  $extra}"
  else
    echo "FAIL $label [$(grep -c '^not ok' "$file") failed]${extra:+  $extra}"
    grep -E '^not ok|^# ' "$file" | tail -20
    fail=1
  fi
}

# Byte-parity between the two template expanders, which live in different runtimes:
# lib/updater.sh render_url (bash, at fetch time) and lib/pin-meta.nix releaseAsset
# (Nix, at eval time). Both must produce the same URL for every pin and system, or a pin update
# drifts silently and only shows up as a build-time hash mismatch.
# One eval lists every pin and system; the bash side expands the same list. Per-pin evals cost
# ~2.9s each (nixpkgs re-imported), which was most of the gate's runtime. It shares nothing with
# the suites, so it runs as a job inside the wave window rather than after every verdict.
parity() {
  local par=0 pins
  local parout
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
  fi
  return "$par"
}

# tests/nix-eval.sh reports the scope's highest memory on stderr. Keep the suite's own output on
# one line and carry the peak alongside it, so the cap is auditable: a suite that balloons shows
# up here instead of only in a separate measurement.
peak=""
body=""
shown=""
split_peak() {
  body=$(printf '%s\n' "$1" | grep -v '^peak=')
  # A suite's verdict is its "OK …" line (with its check count) or nix-unit's own tally; nix's
  # warnings and fetch waits land in the same output, so the verdict line shows the verdict rather
  # than whichever line came first.
  shown=$(printf '%s\n' "$body" | grep -E '^"OK|^🎉' | head -n 1)
  [ -n "$shown" ] || shown=$(printf '%s\n' "$body" | head -n 1)
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
    echo "ok   $label  $shown  $peak"
  else
    split_peak "$out"
    echo "FAIL $label  $peak"
    printf '%s\n' "$body" | tail -20
    fail=1
  fi
}

# gate_job <out-file> <scope> <cmd...> — a gate in the background, verdict written to <out-file>
# and its exit status to <out-file>.rc, so several independent suites can run at once and still
# print one line each, in the order the caller listed them.
gate_job() {
  local out="$1" scope="$2"
  shift 2
  (
    TEST_SCOPE_NAME="$scope" tests/nix-eval.sh "$mem" -- "$@" >"$out" 2>&1
    printf '%s' "$?" >"$out.rc"
  ) &
}

verdict() {
  local label="$1" out="$2"
  split_peak "$(cat "$out")"
  if [ "$(cat "$out.rc")" = 0 ]; then
    echo "ok   $label  $shown  $peak"
  else
    echo "FAIL $label  $peak"
    printf '%s\n' "$body" | tail -20
    fail=1
  fi
}

# throttle <max> — hold until fewer than `max` background jobs are running. Each job is capped at
# `mem` by its own scope, but the sum of concurrent jobs is not, so this is what keeps the
# concurrent peak inside what the machine has free.
throttle() {
  while [ "$(jobs -r | wc -l)" -ge "$1" ]; do wait -n; done
}

# `nix develop` is where the pin updaters run (features/*/update.sh -> lib/updater.sh), so the
# tools they need must resolve from the devShell, not from whatever the host installed. terraform.sh
# is the same claim for the disk tools: the installer ISO is not this devShell, so the gate is where
# "the script only uses tools we ship" gets checked.
#
# One devShell call resolves every tool the gate needs and writes the paths to a file. It used to be
# five devShell evaluations -- this gate, a `nix-unit` probe, the nix-unit run, a `parallel` lookup,
# and the terraform tier -- and the probe and the lookup only re-resolved paths this call already
# produced. nix-unit is printed but not required: absent locally is a skip, absent in CI is a FAIL.
devtools=$(mktemp "${TMPDIR:-/tmp}/gate-tools.XXXXXX")
# The single quotes below are deliberate: `$t` must reach the inner bash unexpanded.
# shellcheck disable=SC2016
gate "nix develop resolves the updater, disk and parallel tools" devshell nix develop --command \
  env DEVTOOLS_OUT="$devtools" bash -c 'rc=0
    for t in curl jq nix bats parallel shellcheck shfmt sfdisk blkid mkfs.vfat mkfs.ext4 mcopy sgdisk nix-unit; do
      p=$(command -v "$t" 2>/dev/null || true)
      printf "%s=%s\n" "$t" "$p" >>"$DEVTOOLS_OUT"
      if [ -z "$p" ] && [ "$t" != nix-unit ]; then rc=1; fi
    done
    exit "$rc"'
devtools_text=$(cat "$devtools")
rm -f "$devtools"
devpath() { printf '%s\n' "$devtools_text" | grep "^$1=" | cut -d= -f2-; }

# The value-tier assertions run as nix-unit test attributes in one process (tests/suite.nix), so a
# failing attribute prints its own diff and the rest keep running instead of the whole suite
# throwing at the first failure. nix-unit comes from the devShell, so this is skipped when absent,
# exactly like the bats tier. --impure because tests/support.nix reads the flake itself.
if [ -n "$(devpath nix-unit)" ]; then
  gate "tests/suite.nix" nix-unit nix develop --command nix-unit --impure tests/suite.nix
else
  missing "tests/suite.nix" "nix-unit not in the devShell"
fi

# These tiers share nothing but the Nix store, so they run concurrently rather than back to back:
# 23s sequential -> 8s, with at most 4 in flight. Each job is still wrapped in its own memory
# scope, so a ballooning suite is killed by the cap instead of swapping the machine, and a failing
# suite still prints its own diff while the others keep running (nix's exit status is the verdict).
#
# home/mounts/wrap force a host config and outputs forces the flake outputs. The four builds check
# what a derivation puts in its $out, which is not an evaluated value: appdir re-runs
# hm-ghostty's real installPhase against a synthetic AppDir (src is a placeholder, so no AppImage is
# ever fetched); brave-layout re-runs hm-brave's real unpackPhase and installPhase over a
# synthetic .deb built by dpkg-deb, where a copy of a store ELF stands in for the patched binary
# (patchelf needs real ELF bytes);
# shellwrap is the shipped writeShellApplication text, which writeShellApplication shellchecks;
# yazi-install unpacks the real pinned sources and re-runs hm-yazi's real postInstall.
# configs.nix evaluates one host per process (see its header): forcing three hosts into one eval
# needs ~4GB, which is over the cap, so they are three jobs here. support.nix is a fixture library
# and asserts nothing, so it is not run.
#
# The lane is split by what the command does. The four fixture builds are the smallest jobs
# (0.3-1.65s, <=423MB) and were holding slots behind 736-1004MB evals, so they go first, inside
# their own subshell: `jobs -r` cannot see a subshell's jobs, so the heavy lane's throttle never
# counts them, and each build still gets its own scope and its own verdict line. The heavy eval
# lane is capped at 3 concurrent -- four heavy evals in flight is ~2.5GB, and the caps are per
# scope, not global (ADR-3ffe3179ebdf).
# One entry per job, "scope|label|cmd". Three parallel arrays had to stay in sync by hand, and
# drifting one silently mislabels a verdict or renames a scope unit -- the scope name is what shows
# up in the telemetry line and in the OOM message. No entry contains a '|'.
wave_jobs=(
  "home|tests/home.nix|nix eval --impure --file tests/home.nix"
  "mounts|tests/mounts.nix|nix eval --impure --file tests/mounts.nix"
  "outputs|tests/outputs.nix|nix eval --impure --file tests/outputs.nix"
  "wrap|tests/wrap.nix|nix eval --impure --file tests/wrap.nix"
  "appdir|tests/appdir.nix [fixture build]|nix build --no-link --quiet -f tests/appdir.nix"
  "brave-layout|tests/brave-layout.nix [deb fixture build]|nix build --no-link --quiet -f tests/brave-layout.nix"
  "shellwrap|tests/shellwrap.nix [wrapper build + shellcheck]|nix build --no-link --quiet -f tests/shellwrap.nix"
  "yazi-install|tests/yazi-install.nix [postInstall fixture]|nix build --no-link --quiet -f tests/yazi-install.nix"
  "configs-methyl|tests/configs.nix [methyl]|env TEST_HOST=methyl nix eval --impure --file tests/configs.nix"
  "configs-methyl-nixos|tests/configs.nix [methyl-nixos]|env TEST_HOST=methyl-nixos nix eval --impure --file tests/configs.nix"
  "configs-propyl|tests/configs.nix [propyl]|env TEST_HOST=propyl nix eval --impure --file tests/configs.nix"
)

# gate_job for one entry: scope up to the first '|', label the next field, cmd the remainder.
launch() {
  local entry="$1" i="$2" scope label
  scope="${entry%%|*}"
  label="${entry#*|}"
  label="${label%%|*}"
  gate_job "$wave/$i" "$scope" bash -c "${entry#*|*|}"
}

(
  for i in "${!wave_jobs[@]}"; do
    case "${wave_jobs[i]}" in *'|nix build '*) launch "${wave_jobs[i]}" "$i" ;; esac
  done
  wait
) &
for i in "${!wave_jobs[@]}"; do
  case "${wave_jobs[i]}" in *'|nix build '*) continue ;; esac
  throttle 3
  launch "${wave_jobs[i]}" "$i"
done
# parity is cheap (31MB) and shares nothing with the suites, so it joins the wave rather than
# taking the last serial stretch of the script.
(
  parity >"$wave/parity" 2>&1
  printf '%s' "$?" >"$wave/parity.rc"
) &
wait
collect "shipped shell lint" "$wave/lint"
for i in "${!wave_jobs[@]}"; do
  label="${wave_jobs[i]#*|}"
  verdict "${label%%|*}" "$wave/$i"
done
collect "expander parity" "$wave/parity"
rm -rf "$wave"

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
# cache-check is the eval-only cache pre-flight: its exit codes (0 clean, 1 naming a cache, 2 bad
# host/argument) and the fact that a host name reaches the Nix expression only after it matched the
# flake's own configurations are argv-level, so tests/cache-check.bats joins them on a stubbed `nix`.
# The cache logic itself is eval-tier: tests/caches.nix on the module, tests/configs.nix on real hosts.
# terraform.sh is the shared-drive half, so tests/terraform.bats runs it against real filesystems in
# files: a blank partition gets really formatted, and a partition another OS owns must come back
# byte-identical. No root, no loop device, no derivation (ADR-b77ec913151f).
# The two bats tiers touch nothing in common — every suite and every fixture gets its own temp dir —
# so they overlap instead of running back to back: 8s + 22s -> ~22s, concurrent peak ~850MB. Each
# keeps its own scope, and the verdicts are still printed one per line, stub tier first.
tiers=$(mktemp -d "${TMPDIR:-/tmp}/bats-tiers.XXXXXX")
if ! command -v bats >/dev/null 2>&1; then
  missing "bats suites" "bats not installed"
  missing "tests/terraform.bats" "bats not installed"
else
  (
    suites=(tests/bootstrap.bats tests/build-harness.bats tests/njust.bats tests/creds.bats
      tests/sopsctl.bats tests/xilo.bats tests/updater.bats tests/install.bats tests/cache-check.bats
      tests/floors.bats tests/ci.bats tests/nix-eval.bats)
    # One bats call with the files in parallel (--no-parallelize-within-files): each suite still runs
    # its tests sequentially inside its own worker, so shared stub state inside a suite survives.
    # `parallel` is borrowed from the devShell onto PATH rather than swapping shells, because
    # creds.bats and sopsctl.bats run the host's real sops/age/systemd-creds. Without it the tier
    # runs sequentially. Measured 35s -> 8s over 291 tests; a failure still names its file.
    jobs=()
    parallel_path=$(devpath parallel)
    if [ -n "$parallel_path" ]; then
      PATH="$(dirname "$parallel_path"):$PATH"
      jobs=(--jobs 8 --no-parallelize-within-files)
    fi
    bats "${jobs[@]}" "${suites[@]}" >"$tiers/stub" 2>&1
    printf '%s' "$?" >"$tiers/stub.rc"
  ) &
  # terraform.bats is not stub-driven: it runs real mkfs, blkid, mtools and sgdisk on sparse files,
  # so it runs in the devShell, which is the environment that carries those tools
  # (ADR-b77ec913151f). Running it plainly would skip it on any machine without them, which is where
  # the proof matters. 16 jobs: the fixture copies are sparse now, so the peak is ~841MB with no
  # swap -- dense copies at 16 jobs put ~637MB of tmpfs into swap, the only way this tier ever
  # touches the SSD. Measured 46s -> 17s, 58/58 green.
  byte=run
  if ! command -v nix >/dev/null 2>&1; then
    byte=skip
  else
    (
      TEST_SCOPE_NAME=terraform tests/nix-eval.sh "$mem" -- nix develop --command \
        bash -c 'bats --jobs 16 tests/terraform.bats' >"$tiers/byte" 2>&1
      printf '%s' "$?" >"$tiers/byte.rc"
    ) &
  fi
  wait
  stub_asserts=$(printf '%s\n' "$floors" | awk '$2 == "assert" && $1 != "tests/terraform.bats" {s+=$3} END{print s+0}')
  bats_verdict "stub bats suites" "$tiers/stub" "$stub_asserts"
  if [ "$byte" = skip ]; then
    missing "tests/terraform.bats" "nix not installed"
  else
    # The scope's peak line is not part of the TAP output, so split it off before reporting.
    split_peak "$(cat "$tiers/byte")"
    byte_asserts=$(printf '%s\n' "$floors" | awk '$2 == "assert" && $1 == "tests/terraform.bats" {s+=$3} END{print s+0}')
    bats_verdict "tests/terraform.bats" "$tiers/byte" "$byte_asserts" "$peak"
  fi
  rm -rf "$tiers"
fi

# Byte-parity and the shipped-shell lint both ran after every verdict, alone; they are jobs in the
# wave above now, so their verdict lines are printed inside the wave window.

exit "$fail"
