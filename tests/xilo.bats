#!/usr/bin/env bats
# features/hm-xilo/xilo.sh against PATH stubs: argv and environment only.
#
# Contract under test: `xilo` is the real CLI, reached by store path, and every subcommand gets
# XILO_URL/XILO_CACHE/XILO_TOKEN filled from credsctl records — unless you already exported that
# variable, which wins. Per-key records win over a bundle, and a record that exists in more than one
# backend is asked for as sops (a name+suffix), because sops decrypts far cheaper than the
# systemd-creds polkit hop; with no per-key record the wrapper reads the bundle `XILO.sops.json` in
# one decrypt. With no credsctl, or no record, the caller's environment is passed through untouched,
# so xilo's own saved profile is what authenticates. argv is never rewritten and the CLI's exit
# status is the wrapper's.
#
# XILO_PROGRAM stands in for the real binary so the wrapper can be run without a build.

load helpers

# The real-binary tests below need the host's own PATH (helpers' host_path): stubs must not shadow
# sops or age-keygen, and an unset host_path would leave `PATH="$real/bin:"` resolving the trailing
# entry to the cwd.
setup() {
  harness_stub_dir
  script="$repo/features/hm-xilo/xilo.sh"
  creds="$stubs/creds"
  mkdir -p "$creds"

  # Quoted heredoc: every $ below is the stub's own runtime variable, not setup's.
  stub xilo-real <<'EOF'
#!/usr/bin/env bash
log="${XILO_STUB_LOG:?}"
printf 'xilo %s\n' "$*" >> "$log"
printf 'xilo-env XILO_URL=%s XILO_TOKEN=%s XILO_CACHE=%s\n' "${XILO_URL:-none}" "${XILO_TOKEN:+set}" "${XILO_CACHE:-none}" >> "$log"
if [ -n "${XILO_SHOW_TOKEN:-}" ]; then printf 'xilo-token [%s]\n' "$XILO_TOKEN" >> "$log"; fi
exit "${XILO_EXIT:-0}"
EOF

  # Real credsctl semantics for the only form the wrapper uses: decrypt --env NAME... -- CMD execs
  # CMD with the secrets in its environment. A bare name resolves .cred first (the wrapper only ever
  # emits a bare name when that is the only file present); a name carrying a suffix names that backend
  # explicitly. A sops record — .sops.json or .sops.yaml — contributes every field, read as json,
  # whatever its own shape; split on NUL, so a multi-line secret survives. Exit 2 means "no record".
  stub credsctl <<'EOF'
#!/usr/bin/env bash
log="${XILO_STUB_LOG:?}"
printf 'credsctl %s\n' "$*" >> "$log"
if [ "$1" = decrypt ] && [ "$2" = --env ]; then
  shift 2
  assigns=()
  while [ "${1:-}" != "--" ]; do
    name="$1"
    base="$name"
    want=""
    case "$name" in
      *.sops.json) base="${name%.sops.json}"; want="$CREDENTIALS_DIRECTORY/$base.sops.json" ;;
      *.sops.yaml) base="${name%.sops.yaml}"; want="$CREDENTIALS_DIRECTORY/$base.sops.yaml" ;;
    esac
    if [ -z "$want" ]; then
      want="$CREDENTIALS_DIRECTORY/$base.cred"
      [ -e "$want" ] || want="$CREDENTIALS_DIRECTORY/$base.sops.json"
      [ -e "$want" ] || want="$CREDENTIALS_DIRECTORY/$base.sops.yaml"
    fi
    [ -e "$want" ] || exit 2
    case "$want" in
      *.sops.json | *.sops.yaml)
        while IFS= read -r -d '' assignment; do
          key="${assignment%%=*}"
          [ "$key" = secret ] && assignment="$base=${assignment#*=}"
          assigns+=("$assignment")
        done < <(jq -j 'to_entries[] | select(.value | type == "string" and length > 0) | "\(.key)=\(.value)\u0000"' "$want")
        ;;
      *) assigns+=("$base=$(cat "$want")") ;;
    esac
    shift
  done
  shift
  exec env "${assigns[@]}" "${@}"
fi
exit 1
EOF
}

run_wrapper() {
  env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" bash "$script" "$@"
}

@test "credentials reach every subcommand, not just push" {
  printf 'https://xilo.test\n' >"$creds/XILO_URL.cred"
  printf 'secret-token\n' >"$creds/XILO_TOKEN.cred"
  printf 'acme/pkgs\n' >"$creds/XILO_CACHE.cred"
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_call '^credsctl decrypt --env XILO_URL XILO_CACHE XILO_TOKEN -- '
  assert_call '^xilo status$'
  assert_call '^xilo-env XILO_URL=https://xilo.test XILO_TOKEN=set XILO_CACHE=acme/pkgs$'
}

@test "argv reaches the real CLI verbatim, including a path argument" {
  run run_wrapper push --jobs 4 --dry-run ./result
  [ "$status" -eq 0 ]
  assert_call '^xilo push --jobs 4 --dry-run ./result$'
}

@test "an exported variable wins over the record" {
  printf 'https://xilo.test\n' >"$creds/XILO_URL.cred"
  printf 'secret-token\n' >"$creds/XILO_TOKEN.cred"
  printf 'acme/pkgs\n' >"$creds/XILO_CACHE.cred"
  env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" XILO_URL=https://from.env \
    bash "$script" push acme/pkgs ./result
  # XILO_URL is skipped, so only the two unset keys are decrypted.
  assert_call '^credsctl decrypt --env XILO_CACHE XILO_TOKEN -- '
  assert_call '^xilo-env XILO_URL=https://from.env XILO_TOKEN=set XILO_CACHE=acme/pkgs$'
}

# The bundle shape: one record whose fields are the variables, read in a single decrypt. systemd-creds
# costs ~1.2s per record (the polkit hop); one sops decrypt costs ~23ms for the whole set.
@test "a bundle record fills every variable in one decrypt" {
  jq -n --arg u 'https://xilo.test' --arg c 'acme/pkgs' --arg t $'tok\nmulti\nline' \
    '{XILO_URL:$u,XILO_CACHE:$c,XILO_TOKEN:$t}' >"$creds/XILO.sops.json"
  run env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" \
    XILO_STUB_LOG="$calls" XILO_SHOW_TOKEN=1 bash "$script" status
  [ "$status" -eq 0 ]
  assert_call '^credsctl decrypt --env XILO.sops.json -- '
  assert_calls '^credsctl' 1
  assert_call '^xilo-env XILO_URL=https://xilo.test XILO_TOKEN=set XILO_CACHE=acme/pkgs$'
  # A multi-line secret arrives whole; splitting the assignments on newlines would truncate it here.
  assert_call '^xilo-token \[tok$'
  assert_call '^multi$'
  assert_call '^line\]$'
}

# A record that exists in more than one backend is asked for by name+suffix, which names the backend
# explicitly: json ahead of yaml ahead of .cred, so the fast one is chosen and the systemd-creds
# record is left alone.
@test "a sops record is preferred over the systemd-creds record for the same key" {
  # The sops records hold plaintext json here: the stub reads a record's fields, not real sops.
  jq -n --arg u 'https://fast.test' '{secret:$u}' >"$creds/XILO_URL.sops.json"
  jq -n --arg u 'https://yaml.test' '{secret:$u}' >"$creds/XILO_URL.sops.yaml"
  printf 'https://slow.test\n' >"$creds/XILO_URL.cred"
  jq -n --arg c 'acme/pkgs' '{secret:$c}' >"$creds/XILO_CACHE.sops.json"
  printf 'secret-token\n' >"$creds/XILO_TOKEN.cred"
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_call '^credsctl decrypt --env XILO_URL.sops.json XILO_CACHE.sops.json XILO_TOKEN -- '
  assert_call '^xilo-env XILO_URL=https://fast.test XILO_TOKEN=set XILO_CACHE=acme/pkgs$'
}

# A yaml record is the same backend, so the wrapper asks for it by suffix too.
@test "a yaml sops record is preferred over the systemd-creds record for the same key" {
  jq -n --arg u 'https://fast.test' '{secret:$u}' >"$creds/XILO_URL.sops.yaml"
  printf 'https://slow.test\n' >"$creds/XILO_URL.cred"
  jq -n --arg c 'acme/pkgs' '{secret:$c}' >"$creds/XILO_CACHE.sops.yaml"
  printf 'secret-token\n' >"$creds/XILO_TOKEN.cred"
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_call '^credsctl decrypt --env XILO_URL.sops.yaml XILO_CACHE.sops.yaml XILO_TOKEN -- '
  assert_call '^xilo-env XILO_URL=https://fast.test XILO_TOKEN=set XILO_CACHE=acme/pkgs$'
}

# --- real binaries: the yaml bundle reaching a consumer ---------------------
#
# End to end with real sops and real credsctl, a mock age key and mock secrets. The point is the
# security properties of the hand-off, not just the values: the wrapper execs the CLI with the
# secrets in its environment only, so the plaintext never appears in the wrapper's own output, never
# in the argv the CLI is given, never as a file, and never in the caller's environment.
@test "a yaml bundle reaches a real consumer through the wrapper, with no plaintext in sight" {
  PATH="$host_path" command -v sops >/dev/null 2>&1 || skip "no sops on the host PATH"
  PATH="$host_path" command -v age-keygen >/dev/null 2>&1 || skip "no age-keygen on the host PATH"
  real="$(mktemp -d)"
  mkdir -p "$real/bin"
  cp "$repo/features/hm-creds/credsctl.sh" "$real/bin/credsctl"
  cp "$repo/features/hm-creds/sopsctl.sh" "$real/bin/sopsctl"
  chmod +x "$real/bin/credsctl" "$real/bin/sopsctl"
  PATH="$host_path" age-keygen -o "$real/key" 2>/dev/null || skip "age-keygen failed"
  grep '^# public key:' "$real/key" | awk '{print $NF}' >"$real/recipient"

  # The consumer reports what it saw as presence markers and a line count — never the values, so a
  # grep for a secret anywhere in the wrapper's output is a real leak test. The markers are named
  # `secret`, not `token`: the leak grep below looks for `tok`, and a `token-set` marker would
  # match it and make the test unsatisfiable.
  cat >"$real/consumer" <<'EOF'
#!/usr/bin/env bash
printf 'consumer argc=%s url-set=%s secret-set=%s cache-set=%s\n' "$#" \
  "${XILO_URL:+set}" "${XILO_TOKEN:+set}" "${XILO_CACHE:+set}"
printf 'consumer secret lines=%s\n' "$(printf '%s\n' "${XILO_TOKEN:-}" | wc -l)"
EOF
  chmod +x "$real/consumer"

  jq -n --arg u 'https://xilo.test' --arg c 'acme/pkgs' --arg t $'tok\nmulti\nline' \
    '{XILO_URL:$u,XILO_CACHE:$c,XILO_TOKEN:$t}' >"$real/fields.json"
  env PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_RECIPIENTS="$real/recipient" SOPS_AGE_FILE="$real/key" \
    bash "$repo/features/hm-creds/credsctl.sh" encrypt XILO.sops.yaml --fields "$real/fields.json"
  before=$(sha256sum "$real/XILO.sops.yaml")

  # Command substitution leaves no `$status`, so the child's exit code is taken from `$?` here —
  # otherwise this test would assert nothing once it stops skipping.
  out=$(env PATH="$real/bin:$host_path" CREDENTIALS_DIRECTORY="$real" SOPS_AGE_FILE="$real/key" \
    XILO_PROGRAM="$real/consumer" bash "$script" push acme/pkgs ./result 2>&1)
  status=$?
  [ "$status" -eq 0 ]
  grep -q 'consumer argc=3 url-set=set secret-set=set cache-set=set' <<<"$out"
  # Three lines is the multi-line value arriving whole as one variable, not split into two.
  grep -q 'consumer secret lines=3' <<<"$out"

  # No secret reaches the wrapper's output, the record is byte-identical, and no decrypted file is
  # written beside it — the plaintext only ever lives in the child's environment.
  run ! grep -q -e 'xilo.test' -e 'acme/pkgs' -e 'multi' -e 'tok' <<<"$out"
  [ "$before" = "$(sha256sum "$real/XILO.sops.yaml")" ]
  # LC_ALL=C so the record sorts first; the host's UTF-8 collation folds case and would not.
  [ "$(find "$real" -type f -not -path "$real/bin/*" | LC_ALL=C sort | tr '\n' ' ')" = \
    "$real/XILO.sops.yaml $real/consumer $real/fields.json $real/key $real/recipient " ]
  rm -rf "$real"
}

# A bundle fills the keys nothing else covers; per-key names are asked for after it, so a per-key
# record overrides the bundle's field for the same variable and both arrive from one decrypt.
@test "a bundle and a per-key record are read in one decrypt" {
  printf 'https://from.record\n' >"$creds/XILO_URL.cred"
  jq -n --arg t 'bundle-token' '{XILO_TOKEN:$t}' >"$creds/XILO.sops.json"
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_call '^credsctl decrypt --env XILO.sops.json XILO_URL -- '
  assert_call '^xilo-env XILO_URL=https://from.record XILO_TOKEN=set XILO_CACHE=none$'
}

# A bundle record's fields are the variables, so the file's own name case is free: `xilo.sops.yaml`
# is the same record as `XILO.sops.yaml`. The wrapper asks for the file that is actually on disk —
# a bare `XILO` would find nothing and drop to systemd-creds — and the fields still fill the
# uppercase variables the CLI reads.
@test "a lowercase bundle record is asked for by its own name and fills the uppercase variables" {
  jq -n --arg u 'https://from.bundle' --arg t 'bundle-token' '{XILO_URL:$u,XILO_TOKEN:$t}' >"$creds/xilo.sops.yaml"
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_call '^credsctl decrypt --env xilo.sops.yaml -- '
  assert_call '^xilo-env XILO_URL=https://from.bundle XILO_TOKEN=set XILO_CACHE=none$'
}

# Both shapes on disk: json first, as before, and a lowercase json still beats a lowercase yaml.
@test "a bundle record prefers .sops.json over .sops.yaml in any case" {
  jq -n '{XILO_URL:"https://from.json"}' >"$creds/xilo.sops.json"
  jq -n '{XILO_URL:"https://from.yaml"}' >"$creds/XILO.sops.yaml"
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_call '^credsctl decrypt --env xilo.sops.json -- '
  assert_call '^xilo-env XILO_URL=https://from.json XILO_TOKEN= XILO_CACHE=none$'
}

# Per-key records stay exact-case: there the filename *is* the variable, so a lowercase
# `xilo_url.sops.json` would fill `xilo_url`, which xilo never reads. Only the bundle is case-free.
@test "a lowercase per-key record is not read as a variable xilo can use" {
  jq -n '{secret:"https://from.record"}' >"$creds/xilo_url.sops.json"
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_no_call '^credsctl'
  assert_call '^xilo-env XILO_URL=none XILO_TOKEN= XILO_CACHE=none$'
}

# An exported variable must not be overridden by a bundle field: credsctl's assignments replace the
# environment, so a bundle is skipped whenever the caller exported one of its variables.
@test "an exported variable skips the bundle entirely" {
  jq -n --arg u 'https://from.bundle' --arg t 'bundle-token' '{XILO_URL:$u,XILO_TOKEN:$t}' >"$creds/XILO.sops.json"
  env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" \
    XILO_STUB_LOG="$calls" XILO_URL=https://from.env bash "$script" status
  assert_call '^xilo-env XILO_URL=https://from.env XILO_TOKEN= XILO_CACHE=none$'
  assert_no_call '^credsctl'
}

@test "no credsctl on PATH leaves the environment alone" {
  printf 'https://xilo.test\n' >"$creds/XILO_URL.cred"
  # /usr/bin has no credsctl (it lives in the nix profile), so this is the real fallback.
  run env PATH=/usr/bin CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" bash "$script" status
  [ "$status" -eq 0 ]
  assert_call '^xilo-env XILO_URL=none XILO_TOKEN= XILO_CACHE=none$'
  assert_no_call credsctl
}

@test "no record at all falls back to xilo's saved profile" {
  run run_wrapper status
  [ "$status" -eq 0 ]
  assert_call '^xilo-env XILO_URL=none XILO_TOKEN= XILO_CACHE=none$'
  assert_no_call '^credsctl'
}

@test "the CLI's exit status is the wrapper's" {
  run env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$creds" XILO_PROGRAM="$stubs/xilo-real" XILO_STUB_LOG="$calls" XILO_EXIT=7 bash "$script" push acme/pkgs ./result
  [ "$status" -eq 7 ]
  assert_call '^xilo push acme/pkgs ./result$'
}
