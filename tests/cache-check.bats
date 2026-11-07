#!/usr/bin/env bats
# lib/cache-check.sh's CLI contract, against a PATH-stubbed `nix`: which exit code each case
# gives, and that a host name reaches the eval expression only after it matches the flake's own
# configurations. No eval, no build, no repo copy — ~0MB.
#
# The cache *logic* is asserted where it is cheap: tests/caches.nix (modules/caches.nix on a bare
# module eval — the warning wording, ready, substituters, keys) and tests/configs.nix (real hosts:
# required == what the features name, and ready). tests/outputs.nix pins that apps.cache-check is a
# runnable app and that its script filters the module's own `flakeCache:` prefix. So what is left
# for this suite is argv and exit status, which is the house pattern for shipped shell.
load helpers

setup() {
  harness_stub_dir
  export CALLS="$calls"

  # Quoted heredoc so the body survives unevaluated. `attrNames` is the host-name lookup; any
  # other call is the warning read-back, whose answer is whatever WARN holds (unset = none).
  stub nix <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >> "$CALLS"
case "$*" in
  *attrNames*) printf '"methyl"\n"methyl-nixos"\n' ;;
  *) [ -n "${WARN:-}" ] && printf '%s\n' "$WARN" ;;
esac
exit 0
EOF
}

# check_ host [warning] — the stub's warning read-back answers `warning` when given, nothing when
# not. The assignment sits on the `bash` command so the stub child actually sees WARN.
check_() {
  local host="$1" warning="${2-}"
  WARN="$warning" PATH="$stubs:$PATH" bash "$repo/lib/cache-check.sh" "$host"
}

# The read-back expression is the only place the host name becomes Nix code.
read_back() { printf 'let cfg = (builtins.getFlake'; }

@test "cache-check exits 0 when the host has no cache warnings" {
  run check_ methyl
  [ "$status" -eq 0 ]
  assert_no_out "flakeCache:"
  assert_call "$(read_back)"
  assert_call 'nixosConfigurations.methyl.config'
}

@test "cache-check exits 1 printing the module's own warning" {
  # The backticks are part of the warning text, not a command substitution (SC2016).
  # shellcheck disable=SC2016
  run check_ methyl 'flakeCache: "https://nix-community.cachix.org" is required by an enabled feature
Add "nix-community" to `flakeCache.enable` to pull it from the cache'
  [ "$status" -eq 1 ]
  assert_out "https://nix-community.cachix.org"
  assert_out 'Add "nix-community" to'
  # The backticks are part of the warning text, not a command substitution (SC2016).
  # shellcheck disable=SC2016
  assert_out '`flakeCache.enable` to pull it from the cache'
}

@test "cache-check refuses a host that is not in the flake, evaluating nothing" {
  run check_ nosuchhost
  [ "$status" -eq 2 ]
  assert_out "unknown host 'nosuchhost'"
  assert_no_call "$(read_back)"
}

@test "cache-check refuses a missing argument" {
  run check_
  [ "$status" -eq 2 ]
  assert_out "usage: cache-check <host>"
  assert_no_call "$(read_back)"
}

# The name goes into the expression only after it matches the flake's configurations, so a
# command-line typo cannot inject Nix code.
@test "a host name that is not a configuration never reaches the expression" {
  run check_ 'methyl"; builtins.trace 1'
  [ "$status" -eq 2 ]
  assert_out "unknown host"
  assert_no_call "$(read_back)"
  assert_no_call 'builtins.trace'
}
