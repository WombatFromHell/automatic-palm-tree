#!/usr/bin/env bats
# features/hm-njust/nix.just against PATH stubs: argv and exit codes only. No root, no real
# /nix, no build. scope = what to build / where the link lives / where it activates,
# mode = build | switch | boot | test | activate | push.
#
# The stub `nix build` writes a closure at the --out-link it was given, shaped like the real
# thing: a homeConfigurations attribute gets `activate` (which takes no argument), a system
# attribute gets `bin/switch-to-configuration`. SWITCH_EXIT / XILO_EXIT make those steps
# fail. The out-links are ephemeral symlinks the recipes create, inside the scratch tree the
# harness teardown removes — nothing here touches shared /tmp.

load helpers

setup() {
  harness_stub_dir
  justfile="$repo/features/hm-njust/nix.just"

  stub nix <<EOF
#!/usr/bin/env bash
echo "nix \$*" >> "$calls"
link=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--out-link" ] && link="\$a"
  prev="\$a"
done
if [ -n "\$link" ]; then
  mkdir -p "\$link/bin"
  case "\$*" in
    *homeConfigurations*)
      printf '#!/usr/bin/env bash\n[ \$# -gt 0 ] && { echo "activate got args: \$*" >&2; exit 1; }\nprintf "homeactivated\\n"\n' > "\$link/activate"
      chmod +x "\$link/activate" ;;
    *)
      printf '#!/usr/bin/env bash\nprintf "switch-to-configuration: %%s\\n" "\$*"\nexit \${SWITCH_EXIT:-0}\n' > "\$link/bin/switch-to-configuration"
      chmod +x "\$link/bin/switch-to-configuration" ;;
  esac
fi
EOF
  # sudo runs the real command, so a failing switch binary fails the activation.
  stub sudo <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$calls"
exec "\$@"
EOF
  stub xilo-wrapped <<EOF
#!/usr/bin/env bash
echo "xilo-wrapped \$*" >> "$calls"
echo "xilo-env XILO_URL=\${XILO_URL:-none} XILO_TOKEN=\${XILO_TOKEN:+set} XILO_CACHE=\${XILO_CACHE:-none}" >> "$calls"
exit \${XILO_EXIT:-0}
EOF
  # credsctl decrypt KEY: the stub is the record contents, and exit 2 means "no record" — which
  # _push only looks up XILO_CACHE; hm-xilo supplies URL/TOKEN (see tests/xilo.bats).
  stub credsctl <<EOF
#!/usr/bin/env bash
if [ -n "\${CREDS_FAIL:-}" ]; then exit "\${CREDS_FAIL}"; fi
if [ "\$1" = decrypt ]; then
  # Mimics credsctl's store chain, so _push is tested through the same override CREDENTIALS_DIRECTORY uses.
  rec="\${CREDS_DIR:-\${CREDENTIALS_DIRECTORY:-\$stubs/creds-none}}/\$2.cred"
  if [ ! -e "\$rec" ]; then exit 2; fi
  cat "\$rec"
fi
EOF

  # The real credential store must not leak into the stub runs; tests point
  # CREDENTIALS_DIRECTORY at their own dir.
  mkdir -p "$stubs/creds-none"
  export CREDENTIALS_DIRECTORY="$stubs/creds-none"

  for tool in ssh nh nixos-rebuild home-manager nix-env nix-store nix-collect-garbage; do
    env_name="${tool^^}"
    env_name="${env_name//-/_}"
    stub "$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit \${${env_name}_EXIT:-0}
EOF
  done
}

# Out-links are symlinks the recipes created inside the scratch tree; teardown removes the tree.
teardown() { harness_teardown; }

# Out-links live in XDG_RUNTIME_DIR, with /tmp as the fallback. The suite pins the variable to
# the scratch dir so every assertion names one place and nothing lands in shared /tmp; tests that
# pass `env -u XDG_RUNTIME_DIR` cover the fallback branch.
njust() { PATH="$stubs:$PATH" XDG_RUNTIME_DIR="$stubs" just --justfile "$justfile" "$@"; }

# --- scope x mode ------------------------------------------------------------

@test "hm builds the user's home closure and names the local activation" {
  run njust hm --dry-run
  [ "$status" -eq 0 ]
  assert_call 'homeConfigurations.*\.activationPackage'
  assert_call '--no-link --dry-run'
  assert_out "would activate: $stubs/hm-result via activate"
  [ ! -e "$stubs/hm-result" ]
}

@test "hm-build builds and activates nothing" {
  run njust hm-build --dry-run
  [ "$status" -eq 0 ]
  assert_call 'nix build .*homeConfigurations'
  assert_no_out 'would activate'
}

@test "hm-activate activates the already-built closure and builds nothing" {
  run njust hm-build
  [ "$status" -eq 0 ]
  : >"$calls"
  run njust hm-activate
  [ "$status" -eq 0 ]
  assert_no_call '^nix build'
  assert_out 'homeactivated'
}

@test "os-switch names the host's config and the switch action" {
  run njust os-switch methyl --dry-run
  [ "$status" -eq 0 ]
  assert_call 'nixosConfigurations\.methyl\.config\.system\.build\.toplevel'
  assert_call '--no-link --dry-run'
  assert_out "would activate: $stubs/nixos-result via switch"
}

@test "os-boot and os-test carry their own action" {
  run njust os-boot methyl --dry-run
  assert_out "would activate: $stubs/nixos-result via boot"
  run njust os-test methyl --dry-run
  assert_out "would activate: $stubs/nixos-result via test"
}

@test "os-build names no activation at all" {
  run njust os-build methyl --dry-run
  [ "$status" -eq 0 ]
  assert_no_out 'would activate'
}

@test "os-activate refuses a generation that was never built" {
  run njust os-activate
  [ "$status" -eq 1 ]
  assert_out "no closure at $stubs/nixos-result"
}

@test "os-activate activates a built closure without building it" {
  run njust os-build methyl
  [ "$status" -eq 0 ]
  : >"$calls"
  run njust os-activate
  [ "$status" -eq 0 ]
  assert_no_call '^nix build'
  assert_call '^sudo .*switch-to-configuration switch$'
}

@test "home-manager has no boot or test action" {
  run env -u XDG_RUNTIME_DIR just --justfile "$justfile" _deploy hm boot
  [ "$status" -eq 1 ]
  assert_out 'home-manager has no'
}

@test "a remote home target is refused, not activated on this host" {
  run njust hm bob@otherhost
  [ "$status" -eq 1 ]
  assert_out 'home activation is local'
  [ "$(wc -l <"$calls")" = 0 ]
}

@test "hm-build still accepts a remote user@host attribute" {
  run njust hm-build bob@otherhost --dry-run
  [ "$status" -eq 0 ]
  assert_call 'homeConfigurations\.bob@otherhost\.activationPackage'
}

# --- activation: local --------------------------------------------------------

@test "local switch sets the system profile and forwards the action as root" {
  run njust os-switch methyl
  [ "$status" -eq 0 ]
  assert_call '^nix-env --profile /nix/var/nix/profiles/system --set .*nixos-result'
  assert_call '^sudo .*switch-to-configuration switch$'
  assert_out 'switch-to-configuration: switch'
  assert_no_call '^ssh'
}

@test "home activation runs as the user, with no argument" {
  run njust hm
  [ "$status" -eq 0 ]
  assert_no_call '^sudo'
  assert_out 'homeactivated'
  assert_no_call 'nix-env\|^sudo'
}

@test "a failing activation fails the recipe" {
  SWITCH_EXIT=1 run njust os-switch methyl
  [ "$status" -ne 0 ]
}

# --- activation: remote -------------------------------------------------------

@test "os-deploy copies the closure and activates over ssh, never locally" {
  run njust os-deploy methyl
  [ "$status" -eq 0 ]
  assert_call '^nix copy --to ssh://deployer@methyl'
  assert_call '^ssh -t deployer@methyl sudo nix-env .* && sudo .*switch-to-configuration boot'
  assert_no_call '^sudo '
}

@test "os-deploy stops before copy and ssh under --dry-run" {
  run njust os-deploy --dry-run methyl
  [ "$status" -eq 0 ]
  assert_out "would activate: $stubs/nixos-deploy-result via boot on deployer@methyl"
  assert_no_call 'ssh://\|^ssh'
}

@test "os-deploy-nas builds another flake with its cache and its ssh alias" {
  run njust os-deploy-nas --dry-run
  [ "$status" -eq 0 ]
  assert_call 'nixosConfigurations.nasty.config'
  assert_call 'https://nasty.cachix.org'
  assert_out "would activate: $stubs/nixos-deploy-result via boot on homenas-deployer"
}

@test "os-deploy-nas never takes a target host" {
  run njust os-deploy-nas --dry-run
  assert_out 'on homenas-deployer'
  assert_no_out 'deployer@'
}

@test "remote deploy reports the manual switch command" {
  run njust os-deploy methyl
  grep -q 'ssh deployer@methyl sudo .*bin/switch-to-configuration switch' <<<"$output"
}

# --- flag parsing -------------------------------------------------------------

@test "a bare token after a valueless flag is still the target" {
  run njust os-build --no-link methyl --dry-run
  [ "$status" -eq 0 ]
  assert_call 'nixosConfigurations.methyl.config'
}

@test "a flag's value never becomes the target" {
  run njust os-build methyl --option gc-auto 1000 --dry-run
  [ "$status" -eq 0 ]
  assert_call 'nixosConfigurations.methyl.config'
  assert_no_call 'nixosConfigurations.gc-auto'
}

@test "activate mode rejects build flags instead of dropping them" {
  run njust os-activate --option gc-auto 1000
  [ "$status" -eq 1 ]
  assert_out "builds nothing"
}

# --- xilo-wrapped push ----------------------------------------------------------------

@test "--with-xilo pushes the built closure once and never reaches the client" {
  run njust os-build methyl --with-xilo
  [ "$status" -eq 0 ]
  assert_call "^xilo-wrapped push default/xilopkgs $stubs/nixos-result$"
  assert_calls 'xilo-wrapped push' 1
  assert_no_call '--with-xilo'
}

@test "hm-push and os-push build then push, activating nothing" {
  run njust hm-push
  [ "$status" -eq 0 ]
  assert_call "^nix build .*homeConfigurations.*\.activationPackage --out-link $stubs/hm-result$"
  assert_call "^xilo-wrapped push default/xilopkgs $stubs/hm-result$"
  assert_no_call '^activate'
  : >"$calls"
  run njust os-push methyl
  [ "$status" -eq 0 ]
  assert_call "^nix build .*nixosConfigurations\.methyl.* --out-link $stubs/nixos-result$"
  assert_call "^xilo-wrapped push default/xilopkgs $stubs/nixos-result$"
  assert_no_call '^sudo '
}

@test "push shortcuts honour XILO_CACHE and never forward the flag" {
  XILO_CACHE=acme/pkgs run njust os-push methyl
  assert_call "^xilo-wrapped push acme/pkgs $stubs/nixos-result$"
  assert_no_call '--with-xilo'
}

@test "no flag, no push" {
  run njust os-build methyl
  [ "$status" -eq 0 ]
  assert_no_call '^xilo-wrapped'
}

@test "--with-xilo under --dry-run names the push and performs nothing" {
  run njust os-build methyl --with-xilo --dry-run
  [ "$status" -eq 0 ]
  assert_out "would push: $stubs/nixos-result"
  assert_no_call '^xilo-wrapped'
}

@test "activation runs before the push" {
  run njust os-switch methyl --with-xilo
  [ "$status" -eq 0 ]
  act="$(grep -n '^sudo .*switch-to-configuration' "$calls" | head -n 1 | cut -d: -f1)"
  push="$(grep -n '^xilo-wrapped push' "$calls" | head -n 1 | cut -d: -f1)"
  [ "$act" -lt "$push" ]
}

@test "a failing activation never pushes" {
  SWITCH_EXIT=1 run njust os-switch methyl --with-xilo
  [ "$status" -ne 0 ]
  assert_no_call '^xilo-wrapped'
}

@test "a failing push fails the deploy" {
  XILO_EXIT=1 run njust os-build methyl --with-xilo
  [ "$status" -ne 0 ]
}

@test "rebuild has no out-link, so --with-xilo is refused" {
  run njust rebuild methyl --with-xilo
  [ "$status" -eq 1 ]
  assert_out '--with-xilo needs a build out-link'
  assert_no_call '^xilo-wrapped'
}

@test "XILO_CACHE overrides the cache name" {
  XILO_CACHE=acme/pkgs run njust os-build methyl --with-xilo
  assert_call "^xilo-wrapped push acme/pkgs $stubs/nixos-result$"
}

# --- activate preview --------------------------------------------------------

# --dry-run is accepted by every recipe, including the modes that build nothing: it previews the
# activation without resolving or running anything.
@test "activate mode previews the activation instead of refusing --dry-run" {
  run njust os-activate --dry-run
  [ "$status" -eq 0 ]
  assert_out "would activate: $stubs/nixos-result via switch"
  [ "$(wc -l <"$calls")" = 0 ]
  run njust hm-activate --dry-run
  [ "$status" -eq 0 ]
  assert_out "would activate: $stubs/hm-result via activate"
  [ "$(wc -l <"$calls")" = 0 ]
}

@test "activate mode still refuses the flags that belong to a build" {
  run njust os-activate --option gc-auto 1000
  [ "$status" -eq 1 ]
  assert_out "builds nothing"
}

# --- rebuild ------------------------------------------------------------------

@test "rebuild runs nixos-rebuild and never forwards --sudo" {
  run njust rebuild --sudo methyl
  [ "$status" -eq 0 ]
  assert_call '^sudo env PATH=.* nixos-rebuild --flake .*methyl'
  assert_no_call '--sudo'
}

@test "rebuild's --dry-run reaches nixos-rebuild, not the print-only runner" {
  run njust rebuild --dry-run methyl
  [ "$status" -eq 0 ]
  assert_call '^sudo env PATH=.*nixos-rebuild.*--dry-run'
}

# --- clean --------------------------------------------------------------------

@test "clean keeps 3 generations and asks, unless you dry-run" {
  run njust clean --dry-run
  assert_out 'nh clean all --dry'
  assert_no_out '--ask'
}

@test "an unlisted long flag stays a flag, not the scope" {
  run njust clean --verbose --dry-run
  assert_out 'nh clean all --verbose'
}

@test "-k keeps its value out of the scope" {
  run njust clean -k 5 --dry-run
  assert_out 'nh clean all -k 5 --dry'
}

# --- traditional cleanup (nix-env / nix profile / store / gcroots) -----------
# `_exec` is the only elevation prefix; generation argv is built in two places, one per profile
# kind: `_gens` for a client's own default profile, `_gens_profile` for an explicit one.
# --dry-run here means "print it, run nothing", unlike nh's own -n.

@test "_exec prints the command and runs nothing on --dry-run" {
  run njust optimise --dry-run
  assert_out 'would run: nix-store --optimise'
  assert_no_call 'nix-store'
}

@test "_exec puts Nix's bin dir first when it elevates" {
  run njust optimise --sudo --dry-run
  grep -q 'would run: sudo env PATH=[^ ]*\.nix-profile/bin:' <<<"$output"
  grep -q 'nix-store --optimise$' <<<"$output"
}

@test "_exec elevated runs the real command" {
  PATH="$stubs:$PATH" njust gc-old --sudo
  assert_call '^nix-collect-garbage --delete-old$'
}

@test "gc is nix store gc with the shared option set" {
  run njust gc --dry-run
  assert_out 'would run: nix store gc --option show-trace true'
}

@test "gc-old takes its duration positionally" {
  run njust gc-older-than 14d --dry-run
  assert_out 'would run: nix-collect-garbage --delete-older-than 14d'
}

@test "list-user lists the user profile with no --profile" {
  run njust list-user --dry-run
  assert_out 'would run: nix-env --list-generations'
}

@test "rm-user refuses an empty spec" {
  run njust rm-user
  [ "$status" -eq 1 ]
  assert_out 'usage: njust rm-user'
}

@test "rm-user keeps nix-env's spec grammar and elevates once" {
  run njust rm-user 30d --sudo --dry-run
  grep -q 'would run: sudo env PATH=.* --delete-generations 30d' <<<"$output"
}

@test "rm-profile takes the profile positionally" {
  d="$(mktemp -d)"
  run njust rm-profile "$d" old --dry-run
  grep -q "would run: nix-env --profile $d --delete-generations old" <<<"$output"
  run njust rm-profile --dry-run
  [ "$status" -eq 1 ]
  rm -rf "$d"
}

@test "hm scopes use home-manager's own verbs" {
  run njust list-hm --dry-run
  assert_out 'would run: home-manager generations'
  run njust rm-hm 15 --dry-run
  assert_out 'would run: home-manager remove-generations 15'
  run njust rm-hm
  [ "$status" -eq 1 ]
}

@test "expire-hm translates nix-env's duration to home-manager's" {
  run njust expire-hm 30d --dry-run
  assert_out 'would run: home-manager expire-generations -30 days'
  run njust expire-hm last-week
  [ "$status" -eq 1 ]
  assert_out 'duration'
}

@test "os scopes need root and skip a profile that is not there" {
  d="$(mktemp -d)"
  touch "$d/profile"
  run env -u XDG_RUNTIME_DIR just --justfile "$justfile" _gens_profile rm "$d/profile" os 14d --dry-run
  grep -q 'would run: sudo env PATH=.* --profile '"$d/profile"' --delete-generations 14d' <<<"$output"
  rm -rf "$d"
  run env -u XDG_RUNTIME_DIR just --justfile "$justfile" list-os /tmp/no-such-profile
  assert_out 'no system profile on this host'
  [ "$status" -eq 0 ]
  assert_no_call 'nix-env'
}

@test "gcroots cover the system and user root dirs" {
  run njust list-roots --dry-run
  assert_out '/nix/var/nix/gcroots/auto'
  assert_out '.local/state/nix/gcroots'
  run njust prune-roots --dry-run
  grep -q 'would run: find -L .* -type l -delete' <<<"$output"
}

@test "sweep is the primitives in order" {
  run njust sweep --dry-run
  assert_out 'would run: home-manager expire-generations -14 days'
  assert_out 'would run: nix-env --delete-generations 14d'
  grep -q 'no system profile on this host' <<<"$output" # this host is not NixOS, so the os step skips
  assert_out 'would run: nix-collect-garbage --delete-old'
  assert_out 'would run: nix-store --optimise'
  assert_out_count 'would run:' 4
}

@test "sweep stops at the first failing step" {
  NIX_COLLECT_GARBAGE_EXIT=1 run njust sweep
  [ "$status" -ne 0 ]
  assert_no_call 'nix-store --optimise'
}

@test "nh's own clean subcommands are passed verbatim through _clean" {
  run njust clean user --no-gcroots --no-direnv --dry -k 5
  assert_out 'nh clean user --no-gcroots --no-direnv --dry -k 5'
}

# --- helpers ------------------------------------------------------------------

# Arguments reach the recipes whole: a value or a glob is one token, never split or expanded
# against the caller's cwd.
# just joins a variadic list when it interpolates it, so a command is handed to `_exec` as one
# string. That is what keeps the quoted token inside the shared option set a single argument.
@test "out-links land in the directory only this user owns" {
  d="$(mktemp -d)"
  PATH="$stubs:$PATH" XDG_RUNTIME_DIR="$d" just --justfile "$justfile" os-build methyl
  [ -e "$d/nixos-result" ]
  # Checked through the stub's recorded arguments rather than by asserting /tmp/nixos-result is
  # absent: that file is a shared path another user or a real `njust` run may have left behind.
  assert_call "--out-link $d/nixos-result"
  assert_no_call "--out-link /tmp/nixos-result"
  rm -rf "$d"
}

@test "the shared option set reaches nix as tokens, not as one joined argument" {
  q="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "argc=%%d %%s\n" "$#" "$*"\n' >"$q/nix"
  chmod +x "$q/nix"
  out="$(PATH="$q:$stubs:$PATH" env -u XDG_RUNTIME_DIR just --justfile "$justfile" os-build methyl)"
  # build + the 9 shared-option tokens (one of them quoted) + attr + --out-link + link; a joined
  # or split argument would change this count.
  grep -q '^argc=13 build .*--option extra-experimental-features nix-command flakes .* --out-link /tmp/nixos-result' <<<"$out"
  rm -rf "$q"
}

@test "build elevates nix build with Nix's bin dir first" {
  run njust os-build methyl --sudo
  [ "$status" -eq 0 ]
  assert_call '^sudo env PATH=.* nix build .*nixosConfigurations\.methyl'
}

@test "the default-profile scopes take a spec, not a profile" {
  run njust rm-user --dry-run
  [ "$status" -eq 1 ]
  assert_out 'usage: njust rm-user'
  run njust rm-hm --dry-run 15
  assert_out 'would run: home-manager remove-generations 15'
}

@test "_resolve finds the closure in every link shape" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure" "$d/result"
  ln -sfn "$d/closure" "$d/link"
  [ "$(env -u XDG_RUNTIME_DIR just --justfile "$justfile" _resolve "$d/link")" = "$d/closure" ]
  [ "$(env -u XDG_RUNTIME_DIR just --justfile "$justfile" _resolve "$d/result")" = "$d/result" ]
  run env -u XDG_RUNTIME_DIR just --justfile "$justfile" _resolve "$d/none"
  [ "$status" -eq 1 ]
  rm -rf "$d"
}

@test "_push hands xilo-wrapped the resolved store path" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure"
  ln -sfn "$d/closure" "$d/link"
  PATH="$stubs:$PATH" just --justfile "$justfile" _push "$d/link"
  assert_call "^xilo-wrapped push default/xilopkgs $d/closure$"
  rm -rf "$d"
}

@test "_push names the cache and leaves credentials to hm-xilo's wrapper" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure" "$d/creds"
  ln -sfn "$d/closure" "$d/link"
  printf 'https://xilo.test\n' >"$d/creds/XILO_URL.cred"
  printf 'secret-token\n' >"$d/creds/XILO_TOKEN.cred"
  PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$d/creds" just --justfile "$justfile" _push "$d/link"
  assert_call "^xilo-wrapped push default/xilopkgs $d/closure$"
  # The recipe exports nothing: the wrapper decrypts URL/TOKEN for its own child.
  assert_call '^xilo-env XILO_URL=none XILO_TOKEN= XILO_CACHE=none$'
  rm -rf "$d"
}

@test "_push takes the cache from XILO_CACHE when it is stored" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure" "$d/creds"
  ln -sfn "$d/closure" "$d/link"
  printf 'https://xilo.test\n' >"$d/creds/XILO_URL.cred"
  printf 'secret-token\n' >"$d/creds/XILO_TOKEN.cred"
  printf 'acme/pkgs\n' >"$d/creds/XILO_CACHE.cred"
  PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$d/creds" just --justfile "$justfile" _push "$d/link"
  assert_call "^xilo-wrapped push acme/pkgs $d/closure$"
  rm -rf "$d"
}

@test "_push takes the default cache name when there is no XILO_CACHE record" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure"
  ln -sfn "$d/closure" "$d/link"
  run env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$d/none" env -u XDG_RUNTIME_DIR just --justfile "$justfile" _push "$d/link"
  [ "$status" -eq 0 ]
  assert_call "^xilo-wrapped push default/xilopkgs $d/closure$"
  rm -rf "$d"
}

@test "_push refuses when xilo-wrapped is not installed" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure"
  ln -sfn "$d/closure" "$d/link"
  # The justfile reads `hostname`/`whoami` at parse time, and every recipe needs bash.
  for t in just bash hostname whoami; do ln -s "$(command -v $t)" "$d/$t"; done
  for t in credsctl sudo nix; do ln -s "$stubs/$t" "$d/$t"; done
  # PATH without the stub xilo-wrapped and without the host profile, so only the guard can answer.
  run env PATH="$d" CREDENTIALS_DIRECTORY="$d/none" just --justfile "$justfile" _push "$d/link"
  [ "$status" -eq 1 ]
  assert_out 'no xilo-wrapped on PATH'
  rm -rf "$d"
}

@test "_push fails loudly when a credential cannot be decrypted" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure" "$d/creds"
  ln -sfn "$d/closure" "$d/link"
  printf 'secret-token\n' >"$d/creds/XILO_CACHE.cred"
  PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$d/creds" CREDS_FAIL=3 run env -u XDG_RUNTIME_DIR just --justfile "$justfile" _push "$d/link"
  [ "$status" -eq 1 ]
  assert_out 'cannot decrypt XILO_CACHE'
  assert_no_call 'xilo-wrapped push'
  rm -rf "$d"
}

# --- flags and the active generation -------------------------------------------

# `-L` (print-build-logs) and `-v` (verbose) are real `nix build` flags. A token starting with
# `-` is a flag, so neither may be read as the target: `os-build methyl -L` must still build
# methyl, not a host named "L".
@test "a short nix flag reaches the client instead of becoming the target" {
  run njust os-build methyl --dry-run -L -v
  [ "$status" -eq 0 ]
  assert_call 'nixosConfigurations.methyl.config.system.build.toplevel'
  assert_call '-L'
  assert_call '-v'
}

@test "rebuild forwards a short flag to nixos-rebuild" {
  run njust rebuild methyl -v
  [ "$status" -eq 0 ]
  assert_call 'nixos-rebuild --flake .*#methyl.* -v$'
}

# push reads the profile symlink, so the recipe needs no out-link and no build. The profile
# path is env-overridable (SYSTEM_PROFILE / XDG_STATE_HOME) — the same seam `flake` uses.
@test "hm-push-active pushes the active home generation and builds nothing" {
  d="$(mktemp -d)"
  mkdir -p "$d/state/nix/profiles" "$d/gen"
  ln -sfn "$d/gen" "$d/state/nix/profiles/home-manager"
  : >"$calls"
  XDG_STATE_HOME="$d/state" run njust hm-push-active
  [ "$status" -eq 0 ]
  assert_call "^xilo-wrapped push default/xilopkgs $d/gen$"
  assert_no_call '^nix build'
  assert_no_call '^sudo '
  # Idempotent: a second run pushes again with no rebuild — xilo uploads only what is missing.
  XDG_STATE_HOME="$d/state" run njust hm-push-active
  [ "$status" -eq 0 ]
  assert_calls '^xilo-wrapped push' 2
  assert_no_call '^nix build'
  rm -rf "$d"
}

@test "os-push-active pushes the booted system generation without activating it" {
  d="$(mktemp -d)"
  mkdir -p "$d/profiles" "$d/toplevel/bin"
  # %%s so the format survives into the stub: os-push-active must never run it, and if it ever did
  # the log would name the arguments it was given, not an empty string.
  printf '#!/usr/bin/env bash\nprintf "switch-to-configuration: %%s\\n" "$*"\n' >"$d/toplevel/bin/switch-to-configuration"
  chmod +x "$d/toplevel/bin/switch-to-configuration"
  ln -sfn "$d/toplevel" "$d/profiles/system"
  : >"$calls"
  SYSTEM_PROFILE="$d/profiles/system" run njust os-push-active
  [ "$status" -eq 0 ]
  assert_call "^xilo-wrapped push default/xilopkgs $d/toplevel$"
  assert_no_call '^nix build'
  assert_no_call 'switch-to-configuration'
  rm -rf "$d"
}

@test "os-push-active refuses a host with no system profile" {
  SYSTEM_PROFILE="$(mktemp -d)/absent" run njust os-push-active
  [ "$status" -eq 1 ]
  assert_out 'no closure at'
  assert_no_call '^xilo-wrapped'
}

# A target names a generation this host does not have active; a flag belongs to a build.
@test "push refuses a target, a flag, and a remote scope" {
  SYSTEM_PROFILE=/nix/var/nix/profiles/system run njust os-push-active methyl
  [ "$status" -eq 1 ]
  assert_out 'already active here'
  SYSTEM_PROFILE=/nix/var/nix/profiles/system run njust os-push-active --option gc-auto 1000
  [ "$status" -eq 1 ]
  assert_out 'builds nothing'
  run njust _deploy os-deploy push
  [ "$status" -eq 1 ]
  assert_out 'activates on a remote host'
}

@test "push previews under --dry-run and uploads nothing" {
  d="$(mktemp -d)"
  mkdir -p "$d/profiles" "$d/top"
  ln -sfn "$d/top" "$d/profiles/system"
  : >"$calls"
  SYSTEM_PROFILE="$d/profiles/system" run njust os-push-active --dry-run
  [ "$status" -eq 0 ]
  assert_out 'would push: '
  assert_no_call '^xilo-wrapped'
  rm -rf "$d"
}
