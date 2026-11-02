#!/usr/bin/env bats
# features/hm-xilo/xilo.sh against PATH stubs: argv and environment only.
#
# Contract under test: `xilo` is the real CLI, reached by store path, and every subcommand gets
# XILO_URL/XILO_CACHE/XILO_TOKEN filled from credsctl records — unless you already exported that
# variable, which wins. With no credsctl, or no record, the caller's environment is passed through
# untouched, so xilo's own saved profile is what authenticates. argv is never rewritten and the
# CLI's exit status is the wrapper's.
#
# XILO_PROGRAM stands in for the real binary so the wrapper can be run without a build.

setup() {
  repo="$PWD"
  script="$repo/features/hm-xilo/xilo.sh"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : > "$calls"
  creds="$stubs/creds"
  mkdir -p "$creds"

  # Quoted heredoc: every $ below is the stub's own runtime variable, not setup's.
  cat > "$stubs/xilo-real" <<'EOF'
#!/usr/bin/env bash
log="${XILO_STUB_LOG:?}"
printf 'xilo %s\n' "$*" >> "$log"
printf 'xilo-env XILO_URL=%s XILO_TOKEN=%s XILO_CACHE=%s\n' "${XILO_URL:-none}" "${XILO_TOKEN:+set}" "${XILO_CACHE:-none}" >> "$log"
exit "${XILO_EXIT:-0}"
EOF
  chmod +x "$stubs/xilo-real"

  # Real credsctl semantics for the only form the wrapper uses: decrypt --env K... -- CMD execs
  # CMD with the secrets in its environment. Exit 2 means "no record".
  # Real credsctl semantics for the one form the wrapper uses: decrypt --env K... -- CMD execs
  # CMD with the secrets in its environment only. Exit 2 means "no record".
  cat > "$stubs/credsctl" <<'EOF'
#!/usr/bin/env bash
log="${XILO_STUB_LOG:?}"
printf 'credsctl %s\n' "$*" >> "$log"
if [ "$1" = decrypt ] && [ "$2" = --env ]; then
  shift 2
  assigns=()
  while [ "${1:-}" != "--" ]; do
    rec="${CREDENTIALS_DIRECTORY:?}/$1.cred"
    [ -e "$rec" ] || exit 2
    assigns+=("$1=$(cat "$rec")")
    shift
  done
  shift
  exec env "${assigns[@]}" "${@}"
fi
exit 1
EOF
  chmod +x "$stubs/credsctl"
}

teardown() { rm -rf "$stubs"; }

run_wrapper() {
  env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" bash "$script" "$@"
}

@test "credentials reach every subcommand, not just push" {
  printf 'https://xilo.test\n' > "$creds/XILO_URL.cred"
  printf 'secret-token\n' > "$creds/XILO_TOKEN.cred"
  printf 'acme/pkgs\n' > "$creds/XILO_CACHE.cred"
  run run_wrapper status
  [ "$status" -eq 0 ]
  grep -q '^credsctl decrypt --env XILO_URL XILO_CACHE XILO_TOKEN -- ' "$calls"
  grep -q '^xilo status$' "$calls"
  grep -q '^xilo-env XILO_URL=https://xilo.test XILO_TOKEN=set XILO_CACHE=acme/pkgs$' "$calls"
}

@test "argv reaches the real CLI verbatim, including a path argument" {
  printf 'https://xilo.test\n' > "$creds/XILO_URL.cred"
  printf 'secret-token\n' > "$creds/XILO_TOKEN.cred"
  run run_wrapper push --jobs 4 --dry-run ./result
  [ "$status" -eq 0 ]
  grep -q '^xilo push --jobs 4 --dry-run ./result$' "$calls"
}

@test "an exported variable wins over the record" {
  printf 'https://xilo.test\n' > "$creds/XILO_URL.cred"
  printf 'secret-token\n' > "$creds/XILO_TOKEN.cred"
  printf 'acme/pkgs\n' > "$creds/XILO_CACHE.cred"
  env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" XILO_URL=https://from.env \
    bash "$script" push acme/pkgs ./result
  # XILO_URL is skipped, so only the two unset keys are decrypted.
  grep -q '^credsctl decrypt --env XILO_CACHE XILO_TOKEN -- ' "$calls"
  grep -q '^xilo-env XILO_URL=https://from.env XILO_TOKEN=set XILO_CACHE=acme/pkgs$' "$calls"
}

@test "no credsctl on PATH leaves the environment alone" {
  printf 'https://xilo.test\n' > "$creds/XILO_URL.cred"
  # /usr/bin has no credsctl (it lives in the nix profile), so this is the real fallback.
  run env PATH=/usr/bin CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" bash "$script" status
  [ "$status" -eq 0 ]
  grep -q '^xilo-env XILO_URL=none XILO_TOKEN= XILO_CACHE=none$' "$calls"
  [ "$(grep -c credsctl "$calls")" = 0 ]
}

@test "no record at all falls back to xilo's saved profile" {
  run run_wrapper status
  [ "$status" -eq 0 ]
  grep -q '^xilo-env XILO_URL=none XILO_TOKEN= XILO_CACHE=none$' "$calls"
  [ "$(grep -c '^credsctl' "$calls")" = 0 ]
}

@test "the CLI's exit status is the wrapper's" {
  run env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" XILO_EXIT=7 bash "$script" push acme/pkgs ./result
  [ "$status" -eq 7 ]
  grep -q '^xilo push acme/pkgs ./result$' "$calls"
}
