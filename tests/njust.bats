#!/usr/bin/env bats
# features/hm-njust/nix.just against PATH stubs: argv and exit codes only. No root, no real
# /nix, no build. scope = what to build / where the link lives / where it activates,
# mode = build | switch | boot | test | activate | push.
#
# The stub `nix build` writes a closure at the --out-link it was given, shaped like the real
# thing: a homeConfigurations attribute gets `activate` (which takes no argument), a system
# attribute gets `bin/switch-to-configuration`. SWITCH_EXIT / XILO_EXIT / NIX_BUILD_EXIT make
# those steps fail. The /tmp out-links are ephemeral symlinks the recipes create; teardown
# removes them (the store paths they point at are untouched).

setup() {
  repo="$PWD"
  justfile="$repo/features/hm-njust/nix.just"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : >"$calls"

  cat >"$stubs/nix" <<EOF
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
exit \${NIX_BUILD_EXIT:-0}
EOF
  chmod +x "$stubs/nix"

  # sudo runs the real command, so a failing switch binary fails the activation.
  cat >"$stubs/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$calls"
exec "\$@"
EOF
  chmod +x "$stubs/sudo"

  cat >"$stubs/xilo-wrapped" <<EOF
#!/usr/bin/env bash
echo "xilo-wrapped \$*" >> "$calls"
echo "xilo-env XILO_URL=\${XILO_URL:-none} XILO_TOKEN=\${XILO_TOKEN:+set} XILO_CACHE=\${XILO_CACHE:-none}" >> "$calls"
exit \${XILO_EXIT:-0}
EOF
  chmod +x "$stubs/xilo-wrapped"

  # credsctl decrypt KEY: the stub is the record contents, and exit 2 means "no record" — which
  # _push only looks up XILO_CACHE; hm-xilo supplies URL/TOKEN (see tests/xilo.bats).
  cat >"$stubs/credsctl" <<EOF
#!/usr/bin/env bash
if [ -n "\${CREDS_FAIL:-}" ]; then exit "\${CREDS_FAIL}"; fi
if [ "\$1" = decrypt ]; then
  # Mimics credsctl's store chain, so _push is tested through the same override CREDENTIALS_DIRECTORY uses.
  rec="\${CREDS_DIR:-\${CREDENTIALS_DIRECTORY:-\$stubs/creds-none}}/\$2.cred"
  if [ ! -e "\$rec" ]; then exit 2; fi
  cat "\$rec"
fi
EOF
  chmod +x "$stubs/credsctl"

  # The real credential store must not leak into the stub runs; tests point
  # CREDENTIALS_DIRECTORY at their own dir.
  mkdir -p "$stubs/creds-none"
  export CREDENTIALS_DIRECTORY="$stubs/creds-none"

  for tool in ssh nh nixos-rebuild home-manager nix-env nix-store nix-collect-garbage; do
    env_name="${tool^^}"
    env_name="${env_name//-/_}"
    cat >"$stubs/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit \${${env_name}_EXIT:-0}
EOF
    chmod +x "$stubs/$tool"
  done
}

teardown() { rm -rf "$stubs" /tmp/hm-result /tmp/nixos-result /tmp/nixos-deploy-result; }

# Out-links live in a per-user directory (XDG_RUNTIME_DIR, /tmp as fallback). The suite pins that
# to /tmp so every assertion names one place; one test covers the private case.
njust() { PATH="$stubs:$PATH" env -u XDG_RUNTIME_DIR just --justfile "$justfile" "$@"; }

# --- scope x mode ------------------------------------------------------------

@test "hm builds the user's home closure and names the local activation" {
  run njust hm --dry-run
  [ "$status" -eq 0 ]
  grep -q 'homeConfigurations.*\.activationPackage' "$calls"
  grep -q -- '--no-link --dry-run' "$calls"
  grep -q 'would activate: /tmp/hm-result via activate' <<<"$output"
  [ ! -e /tmp/hm-result ]
}

@test "hm-build builds and activates nothing" {
  run njust hm-build --dry-run
  [ "$status" -eq 0 ]
  grep -q 'nix build .*homeConfigurations' "$calls"
  [ "$(grep -c 'would activate' <<<"$output")" = 0 ]
}

@test "hm-activate activates the already-built closure and builds nothing" {
  run njust hm-build
  [ "$status" -eq 0 ]
  : >"$calls"
  run njust hm-activate
  [ "$status" -eq 0 ]
  [ "$(grep -c '^nix build' "$calls")" = 0 ]
  grep -q 'homeactivated' <<<"$output"
}

@test "os-switch names the host's config and the switch action" {
  run njust os-switch methyl --dry-run
  [ "$status" -eq 0 ]
  grep -q 'nixosConfigurations\.methyl\.config\.system\.build\.toplevel' "$calls"
  grep -q -- '--no-link --dry-run' "$calls"
  grep -q 'would activate: /tmp/nixos-result via switch' <<<"$output"
}

@test "os-boot and os-test carry their own action" {
  run njust os-boot methyl --dry-run
  grep -q 'would activate: /tmp/nixos-result via boot' <<<"$output"
  run njust os-test methyl --dry-run
  grep -q 'would activate: /tmp/nixos-result via test' <<<"$output"
}

@test "os-build names no activation at all" {
  run njust os-build methyl --dry-run
  [ "$status" -eq 0 ]
  [ "$(grep -c 'would activate' <<<"$output")" = 0 ]
}

@test "os-activate refuses a generation that was never built" {
  run njust os-activate
  [ "$status" -eq 1 ]
  grep -q 'no closure at /tmp/nixos-result' <<<"$output"
}

@test "os-activate activates a built closure without building it" {
  run njust os-build methyl
  [ "$status" -eq 0 ]
  : >"$calls"
  run njust os-activate
  [ "$status" -eq 0 ]
  [ "$(grep -c '^nix build' "$calls")" = 0 ]
  grep -q '^sudo .*switch-to-configuration switch$' "$calls"
}

@test "home-manager has no boot or test action" {
  run env -u XDG_RUNTIME_DIR just --justfile "$justfile" _deploy hm boot
  [ "$status" -eq 1 ]
  grep -q 'home-manager has no' <<<"$output"
}

@test "a remote home target is refused, not activated on this host" {
  run njust hm bob@otherhost
  [ "$status" -eq 1 ]
  grep -q 'home activation is local' <<<"$output"
  [ "$(wc -l <"$calls")" = 0 ]
}

@test "hm-build still accepts a remote user@host attribute" {
  run njust hm-build bob@otherhost --dry-run
  [ "$status" -eq 0 ]
  grep -q 'homeConfigurations\.bob@otherhost\.activationPackage' "$calls"
}

# --- activation: local --------------------------------------------------------

@test "local switch sets the system profile and forwards the action as root" {
  run njust os-switch methyl
  [ "$status" -eq 0 ]
  grep -q '^nix-env --profile /nix/var/nix/profiles/system --set .*nixos-result' "$calls"
  grep -q '^sudo .*switch-to-configuration switch$' "$calls"
  grep -q 'switch-to-configuration: switch' <<<"$output"
  [ "$(grep -c '^ssh' "$calls")" = 0 ]
}

@test "home activation runs as the user, with no argument" {
  run njust hm
  [ "$status" -eq 0 ]
  [ "$(grep -c '^sudo' "$calls")" = 0 ]
  grep -q 'homeactivated' <<<"$output"
  [ "$(grep -c 'nix-env\|^sudo' "$calls")" = 0 ]
}

@test "a failing activation fails the recipe" {
  SWITCH_EXIT=1 run njust os-switch methyl
  [ "$status" -ne 0 ]
}

# --- activation: remote -------------------------------------------------------

@test "os-deploy copies the closure and activates over ssh, never locally" {
  run njust os-deploy methyl
  [ "$status" -eq 0 ]
  grep -q '^nix copy --to ssh://deployer@methyl' "$calls"
  grep -q '^ssh -t deployer@methyl sudo nix-env .* && sudo .*switch-to-configuration boot' "$calls"
  [ "$(grep -c '^sudo ' "$calls")" = 0 ]
}

@test "os-deploy stops before copy and ssh under --dry-run" {
  run njust os-deploy --dry-run methyl
  [ "$status" -eq 0 ]
  grep -q 'would activate: /tmp/nixos-deploy-result via boot on deployer@methyl' <<<"$output"
  [ "$(grep -c 'ssh://\|^ssh' "$calls")" = 0 ]
}

@test "os-deploy-nas builds another flake with its cache and its ssh alias" {
  run njust os-deploy-nas --dry-run
  [ "$status" -eq 0 ]
  grep -q 'nixosConfigurations.nasty.config' "$calls"
  grep -q 'https://nasty.cachix.org' "$calls"
  grep -q 'would activate: /tmp/nixos-deploy-result via boot on homenas-deployer' <<<"$output"
}

@test "os-deploy-nas never takes a target host" {
  run njust os-deploy-nas --dry-run
  grep -q 'on homenas-deployer' <<<"$output"
  [ "$(grep -c 'deployer@' <<<"$output")" = 0 ]
}

@test "remote deploy reports the manual switch command" {
  run njust os-deploy methyl
  grep -q 'ssh deployer@methyl sudo .*bin/switch-to-configuration switch' <<<"$output"
}

# --- flag parsing -------------------------------------------------------------

@test "a bare token after a valueless flag is still the target" {
  run njust os-build --no-link methyl --dry-run
  [ "$status" -eq 0 ]
  grep -q 'nixosConfigurations.methyl.config' "$calls"
}

@test "a flag's value never becomes the target" {
  run njust os-build methyl --option gc-auto 1000 --dry-run
  [ "$status" -eq 0 ]
  grep -q 'nixosConfigurations.methyl.config' "$calls"
  [ "$(grep -c 'nixosConfigurations.gc-auto' "$calls")" = 0 ]
}

@test "activate mode rejects build flags instead of dropping them" {
  run njust os-activate --option gc-auto 1000
  [ "$status" -eq 1 ]
  grep -q "builds nothing" <<<"$output"
}

# --- xilo-wrapped push ----------------------------------------------------------------

@test "--with-xilo pushes the built closure once and never reaches the client" {
  run njust os-build methyl --with-xilo
  [ "$status" -eq 0 ]
  grep -q '^xilo-wrapped push default/xilopkgs /tmp/nixos-result$' "$calls"
  [ "$(grep -c 'xilo-wrapped push' "$calls")" = 1 ]
  [ "$(grep -c -- '--with-xilo' "$calls")" = 0 ]
}

@test "hm-push and os-push build then push, activating nothing" {
  run njust hm-push
  [ "$status" -eq 0 ]
  grep -q '^nix build .*homeConfigurations.*\.activationPackage --out-link /tmp/hm-result$' "$calls"
  grep -q '^xilo-wrapped push default/xilopkgs /tmp/hm-result$' "$calls"
  [ "$(grep -c '^activate' "$calls")" = 0 ]
  : >"$calls"
  run njust os-push methyl
  [ "$status" -eq 0 ]
  grep -q '^nix build .*nixosConfigurations\.methyl.* --out-link /tmp/nixos-result$' "$calls"
  grep -q '^xilo-wrapped push default/xilopkgs /tmp/nixos-result$' "$calls"
  [ "$(grep -c '^sudo ' "$calls")" = 0 ]
}

@test "push shortcuts honour XILO_CACHE and never forward the flag" {
  XILO_CACHE=acme/pkgs run njust os-push methyl
  grep -q '^xilo-wrapped push acme/pkgs /tmp/nixos-result$' "$calls"
  [ "$(grep -c -- '--with-xilo' "$calls")" = 0 ]
}

@test "no flag, no push" {
  run njust os-build methyl
  [ "$status" -eq 0 ]
  [ "$(grep -c '^xilo-wrapped' "$calls")" = 0 ]
}

@test "--with-xilo under --dry-run names the push and performs nothing" {
  run njust os-build methyl --with-xilo --dry-run
  [ "$status" -eq 0 ]
  grep -q 'would push: /tmp/nixos-result' <<<"$output"
  [ "$(grep -c '^xilo-wrapped' "$calls")" = 0 ]
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
  [ "$(grep -c '^xilo-wrapped' "$calls")" = 0 ]
}

@test "a failing push fails the deploy" {
  XILO_EXIT=1 run njust os-build methyl --with-xilo
  [ "$status" -ne 0 ]
}

@test "rebuild has no out-link, so --with-xilo is refused" {
  run njust rebuild methyl --with-xilo
  [ "$status" -eq 1 ]
  grep -q -- '--with-xilo needs a build out-link' <<<"$output"
  [ "$(grep -c '^xilo-wrapped' "$calls")" = 0 ]
}

@test "XILO_CACHE overrides the cache name" {
  XILO_CACHE=acme/pkgs run njust os-build methyl --with-xilo
  grep -q '^xilo-wrapped push acme/pkgs /tmp/nixos-result$' "$calls"
}

# --- activate preview --------------------------------------------------------

# --dry-run is accepted by every recipe, including the modes that build nothing: it previews the
# activation without resolving or running anything.
@test "activate mode previews the activation instead of refusing --dry-run" {
  run njust os-activate --dry-run
  [ "$status" -eq 0 ]
  grep -q 'would activate: /tmp/nixos-result via switch' <<<"$output"
  [ "$(wc -l <"$calls")" = 0 ]
  run njust hm-activate --dry-run
  [ "$status" -eq 0 ]
  grep -q 'would activate: /tmp/hm-result via activate' <<<"$output"
  [ "$(wc -l <"$calls")" = 0 ]
}

@test "activate mode still refuses the flags that belong to a build" {
  run njust os-activate --option gc-auto 1000
  [ "$status" -eq 1 ]
  grep -q "builds nothing" <<<"$output"
}

# --- rebuild ------------------------------------------------------------------

@test "rebuild runs nixos-rebuild and never forwards --sudo" {
  run njust rebuild --sudo methyl
  [ "$status" -eq 0 ]
  grep -q '^sudo env PATH=.* nixos-rebuild --flake .*methyl' "$calls"
  [ "$(grep -c -- '--sudo' "$calls")" = 0 ]
}

@test "rebuild's --dry-run reaches nixos-rebuild, not the print-only runner" {
  run njust rebuild --dry-run methyl
  [ "$status" -eq 0 ]
  grep -q '^sudo env PATH=.*nixos-rebuild.*--dry-run' "$calls"
}

# --- clean --------------------------------------------------------------------

@test "clean keeps 3 generations and asks, unless you dry-run" {
  run njust clean --dry-run
  grep -q 'nh clean all --dry' <<<"$output"
  [ "$(grep -c -- '--ask' <<<"$output")" = 0 ]
}

@test "an unlisted long flag stays a flag, not the scope" {
  run njust clean --verbose --dry-run
  grep -q 'nh clean all --verbose' <<<"$output"
}

@test "-k keeps its value out of the scope" {
  run njust clean -k 5 --dry-run
  grep -q 'nh clean all -k 5 --dry' <<<"$output"
}

# --- traditional cleanup (nix-env / nix profile / store / gcroots) -----------
# `_exec` is the only elevation prefix; generation argv is built in two places, one per profile
# kind: `_gens` for a client's own default profile, `_gens_profile` for an explicit one.
# --dry-run here means "print it, run nothing", unlike nh's own -n.

@test "_exec prints the command and runs nothing on --dry-run" {
  run njust optimise --dry-run
  grep -q 'would run: nix-store --optimise' <<<"$output"
  [ "$(grep -c 'nix-store' "$calls")" = 0 ]
}

@test "_exec puts Nix's bin dir first when it elevates" {
  run njust optimise --sudo --dry-run
  grep -q 'would run: sudo env PATH=[^ ]*\.nix-profile/bin:' <<<"$output"
  grep -q 'nix-store --optimise$' <<<"$output"
}

@test "_exec elevated runs the real command" {
  PATH="$stubs:$PATH" njust gc-old --sudo
  grep -q '^nix-collect-garbage --delete-old$' "$calls"
}

@test "gc is nix store gc with the shared option set" {
  run njust gc --dry-run
  grep -q 'would run: nix store gc --option show-trace true' <<<"$output"
}

@test "gc-old takes its duration positionally" {
  run njust gc-older-than 14d --dry-run
  grep -q 'would run: nix-collect-garbage --delete-older-than 14d' <<<"$output"
}

@test "list-user lists the user profile with no --profile" {
  run njust list-user --dry-run
  grep -q 'would run: nix-env --list-generations' <<<"$output"
}

@test "rm-user refuses an empty spec" {
  run njust rm-user
  [ "$status" -eq 1 ]
  grep -q 'usage: njust rm-user' <<<"$output"
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
  grep -q 'would run: home-manager generations' <<<"$output"
  run njust rm-hm 15 --dry-run
  grep -q 'would run: home-manager remove-generations 15' <<<"$output"
  run njust rm-hm
  [ "$status" -eq 1 ]
}

@test "expire-hm translates nix-env's duration to home-manager's" {
  run njust expire-hm 30d --dry-run
  grep -q 'would run: home-manager expire-generations -30 days' <<<"$output"
  run njust expire-hm last-week
  [ "$status" -eq 1 ]
  grep -q 'duration' <<<"$output"
}

@test "os scopes need root and skip a profile that is not there" {
  d="$(mktemp -d)"
  touch "$d/profile"
  run env -u XDG_RUNTIME_DIR just --justfile "$justfile" _gens_profile rm "$d/profile" os 14d --dry-run
  grep -q 'would run: sudo env PATH=.* --profile '"$d/profile"' --delete-generations 14d' <<<"$output"
  rm -rf "$d"
  run env -u XDG_RUNTIME_DIR just --justfile "$justfile" list-os /tmp/no-such-profile
  grep -q 'no system profile on this host' <<<"$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'nix-env' "$calls")" = 0 ]
}

@test "gcroots cover the system and user root dirs" {
  run njust list-roots --dry-run
  grep -q '/nix/var/nix/gcroots/auto' <<<"$output"
  grep -q '.local/state/nix/gcroots' <<<"$output"
  run njust prune-roots --dry-run
  grep -q 'would run: find -L .* -type l -delete' <<<"$output"
}

@test "sweep is the primitives in order" {
  run njust sweep --dry-run
  grep -q 'would run: home-manager expire-generations -14 days' <<<"$output"
  grep -q 'would run: nix-env --delete-generations 14d' <<<"$output"
  grep -q 'no system profile on this host' <<<"$output" # this host is not NixOS, so the os step skips
  grep -q 'would run: nix-collect-garbage --delete-old' <<<"$output"
  grep -q 'would run: nix-store --optimise' <<<"$output"
  [ "$(grep -c 'would run:' <<<"$output")" = 4 ]
}

@test "sweep stops at the first failing step" {
  NIX_COLLECT_GARBAGE_EXIT=1 run njust sweep
  [ "$status" -ne 0 ]
  [ "$(grep -c 'nix-store --optimise' "$calls")" = 0 ]
}

@test "nh's own clean subcommands are passed verbatim through _clean" {
  run njust clean user --no-gcroots --no-direnv --dry -k 5
  grep -q 'nh clean user --no-gcroots --no-direnv --dry -k 5' <<<"$output"
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
  grep -q -- "--out-link $d/nixos-result" "$calls"
  run ! grep -q -- "--out-link /tmp/nixos-result" "$calls"
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
  grep -q '^sudo env PATH=.* nix build .*nixosConfigurations\.methyl' "$calls"
}

@test "the default-profile scopes take a spec, not a profile" {
  run njust rm-user --dry-run
  [ "$status" -eq 1 ]
  grep -q 'usage: njust rm-user' <<<"$output"
  run njust rm-hm --dry-run 15
  grep -q 'would run: home-manager remove-generations 15' <<<"$output"
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
  grep -q "^xilo-wrapped push default/xilopkgs $d/closure$" "$calls"
  rm -rf "$d"
}

@test "_push names the cache and leaves credentials to hm-xilo's wrapper" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure" "$d/creds"
  ln -sfn "$d/closure" "$d/link"
  printf 'https://xilo.test\n' >"$d/creds/XILO_URL.cred"
  printf 'secret-token\n' >"$d/creds/XILO_TOKEN.cred"
  PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$d/creds" just --justfile "$justfile" _push "$d/link"
  grep -q "^xilo-wrapped push default/xilopkgs $d/closure$" "$calls"
  # The recipe exports nothing: the wrapper decrypts URL/TOKEN for its own child.
  grep -q '^xilo-env XILO_URL=none XILO_TOKEN= XILO_CACHE=none$' "$calls"
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
  grep -q "^xilo-wrapped push acme/pkgs $d/closure$" "$calls"
  rm -rf "$d"
}

@test "_push takes the default cache name when there is no XILO_CACHE record" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure"
  ln -sfn "$d/closure" "$d/link"
  run env PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$d/none" env -u XDG_RUNTIME_DIR just --justfile "$justfile" _push "$d/link"
  [ "$status" -eq 0 ]
  grep -q "^xilo-wrapped push default/xilopkgs $d/closure$" "$calls"
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
  grep -q 'no xilo-wrapped on PATH' <<<"$output"
  rm -rf "$d"
}

@test "_push fails loudly when a credential cannot be decrypted" {
  d="$(mktemp -d)"
  mkdir -p "$d/closure" "$d/creds"
  ln -sfn "$d/closure" "$d/link"
  printf 'secret-token\n' >"$d/creds/XILO_CACHE.cred"
  PATH="$stubs:$PATH" CREDENTIALS_DIRECTORY="$d/creds" CREDS_FAIL=3 run env -u XDG_RUNTIME_DIR just --justfile "$justfile" _push "$d/link"
  [ "$status" -eq 1 ]
  grep -q 'cannot decrypt XILO_CACHE' <<<"$output"
  [ "$(grep -c 'xilo-wrapped push' "$calls")" = 0 ]
  rm -rf "$d"
}

# --- flags and the active generation -------------------------------------------

# `-L` (print-build-logs) and `-v` (verbose) are real `nix build` flags. A token starting with
# `-` is a flag, so neither may be read as the target: `os-build methyl -L` must still build
# methyl, not a host named "L".
@test "a short nix flag reaches the client instead of becoming the target" {
  run njust os-build methyl --dry-run -L -v
  [ "$status" -eq 0 ]
  grep -q 'nixosConfigurations.methyl.config.system.build.toplevel' "$calls"
  grep -q -- '-L' "$calls"
  grep -q -- '-v' "$calls"
}

@test "rebuild forwards a short flag to nixos-rebuild" {
  run njust rebuild methyl -v
  [ "$status" -eq 0 ]
  grep -q 'nixos-rebuild --flake .*#methyl.* -v$' "$calls"
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
  grep -q "^xilo-wrapped push default/xilopkgs $d/gen$" "$calls"
  [ "$(grep -c '^nix build' "$calls")" = 0 ]
  [ "$(grep -c '^sudo ' "$calls")" = 0 ]
  # Idempotent: a second run pushes again with no rebuild — xilo uploads only what is missing.
  XDG_STATE_HOME="$d/state" run njust hm-push-active
  [ "$status" -eq 0 ]
  [ "$(grep -c '^xilo-wrapped push' "$calls")" = 2 ]
  [ "$(grep -c '^nix build' "$calls")" = 0 ]
  rm -rf "$d"
}

@test "os-push-active pushes the booted system generation without activating it" {
  d="$(mktemp -d)"
  mkdir -p "$d/profiles" "$d/toplevel/bin"
  printf '#!/usr/bin/env bash\nprintf "switch-to-configuration: %s\\n" "$*"\n' >"$d/toplevel/bin/switch-to-configuration"
  chmod +x "$d/toplevel/bin/switch-to-configuration"
  ln -sfn "$d/toplevel" "$d/profiles/system"
  : >"$calls"
  SYSTEM_PROFILE="$d/profiles/system" run njust os-push-active
  [ "$status" -eq 0 ]
  grep -q "^xilo-wrapped push default/xilopkgs $d/toplevel$" "$calls"
  [ "$(grep -c '^nix build' "$calls")" = 0 ]
  [ "$(grep -c 'switch-to-configuration' "$calls")" = 0 ]
  rm -rf "$d"
}

@test "os-push-active refuses a host with no system profile" {
  SYSTEM_PROFILE="$(mktemp -d)/absent" run njust os-push-active
  [ "$status" -eq 1 ]
  grep -q 'no closure at' <<<"$output"
  [ "$(grep -c '^xilo-wrapped' "$calls")" = 0 ]
}

# A target names a generation this host does not have active; a flag belongs to a build.
@test "push refuses a target, a flag, and a remote scope" {
  SYSTEM_PROFILE=/nix/var/nix/profiles/system run njust os-push-active methyl
  [ "$status" -eq 1 ]
  grep -q 'already active here' <<<"$output"
  SYSTEM_PROFILE=/nix/var/nix/profiles/system run njust os-push-active --option gc-auto 1000
  [ "$status" -eq 1 ]
  grep -q 'builds nothing' <<<"$output"
  run njust _deploy os-deploy push
  [ "$status" -eq 1 ]
  grep -q 'activates on a remote host' <<<"$output"
}

@test "push previews under --dry-run and uploads nothing" {
  d="$(mktemp -d)"
  mkdir -p "$d/profiles" "$d/top"
  ln -sfn "$d/top" "$d/profiles/system"
  : >"$calls"
  SYSTEM_PROFILE="$d/profiles/system" run njust os-push-active --dry-run
  [ "$status" -eq 0 ]
  grep -q 'would push: ' <<<"$output"
  [ "$(grep -c '^xilo-wrapped' "$calls")" = 0 ]
  rm -rf "$d"
}
