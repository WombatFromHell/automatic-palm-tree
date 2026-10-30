#!/usr/bin/env bats
# bootstrap.sh against PATH stubs: argv and exit codes only. No root, no real /nix, no curl, no eval.

setup() {
  repo="$PWD"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : > "$calls"
  # nix answers only the two calls bootstrap makes: `store info` and the registry eval.
  cat > "$stubs/nix" <<EOF
#!/usr/bin/env bash
echo "nix \$*" >> "$calls"
if [ "\$1 \$2" = "store info" ]; then
  if [ "\${NIX_INFO_EXIT:-0}" != 0 ]; then echo "error: cannot connect to the nix daemon" >&2; exit 1; fi
  printf 'Trusted: %s\n' "\${TRUSTED:-1}" >&2
  exit 0
fi
case "\$6" in
  substituters) printf 'https://cache.example/x 1\n' ;;
  trustedPublicKeys) printf 'cache.example:2\n' ;;
  *) exit 1 ;;
esac
EOF
  for tool in sudo home-manager nixos-rebuild nix-channel nix-shell systemd-run; do
    env_name="${tool^^}"; env_name="${env_name//-/_}"
    cat > "$stubs/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit \${${env_name}_EXIT:-0}
EOF
    chmod +x "$stubs/$tool"
  done
  chmod +x "$stubs/nix"
}

teardown() { rm -rf "$stubs"; }

run_boot() { PATH="$stubs:$PATH" bash "$repo/bootstrap.sh" "$@"; }

@test "bare host: sudo nixos-rebuild boot with the bootloader flag and the registry caches" {
  run run_boot methyl
  [ "$status" -eq 0 ]
  grep -q "sudo nixos-rebuild boot --install-bootloader --flake .*#methyl" "$calls"
  grep -q -- "--option extra-substituters https://cache.example/x 1" "$calls"
  grep -q -- "--option extra-trusted-public-keys cache.example:2" "$calls"
}

@test "user@host: home-manager switch, caches injected" {
  run run_boot josh@example.test
  [ "$status" -eq 0 ]
  grep -q "home-manager switch --flake .*#josh@example.test" "$calls"
  grep -q -- "--option extra-substituters" "$calls"
}

@test "--standalone refuses a bare host: it has no NixOS config to rebuild" {
  run run_boot --standalone methyl
  [ "$status" -eq 2 ]
  [[ "$output" == *"--standalone target must be"* ]]
}

@test "--rebind on a box that already has Nix is refused, not dropped" {
  run run_boot --standalone --rebind=/mnt/data1/nix josh@example.test
  [ "$status" -eq 2 ]
  [[ "$output" == *"fresh install"* ]]
}

@test "--rebind= with no directory is refused" {
  run run_boot --standalone --rebind= josh@example.test
  [ "$status" -eq 2 ]
  [[ "$output" == *"--rebind needs a directory"* ]]
}

@test "--standalone cannot report success when trust did not take effect" {
  TRUSTED=0 run run_boot --standalone
  [ "$status" -eq 2 ]
  [[ "$output" == *"still not a trusted nix user"* ]]
}

@test "an untrusted switch names the daemon, not just the user" {
  TRUSTED=0 run run_boot josh@example.test
  [ "$status" -eq 2 ]
  [[ "$output" == *"nix daemon"* ]]
}

@test "a daemon that does not answer is not reported as an untrusted user" {
  NIX_INFO_EXIT=1 run run_boot josh@example.test
  [ "$status" -eq 2 ]
  [[ "$output" == *"nix store info"* ]]
}
@test "--rebind reaches the installer as --persistence" {
  # The installer path only runs where Nix is genuinely absent; this box has a receipt.
  [ -f /nix/receipt.json ] && skip "/nix/receipt.json present — installer path cannot run here"
  rm "$stubs/nix"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\nprintf "#!/bin/sh\\nexit 0\\n"\n' "$calls" > "$stubs/curl"
  chmod +x "$stubs/curl"
  PATH="$stubs:/usr/bin:/bin" bash "$repo/bootstrap.sh" --standalone --rebind=/mnt/data1/nix || true
  grep -q "install ostree --enable-flakes --persistence /mnt/data1/nix" "$calls"
}

@test "a failing systemd-run still runs the rebuild, unwrapped" {
  SYSTEMD_RUN_EXIT=1 run run_boot methyl
  [ "$status" -eq 0 ]
  grep -q "^sudo nixos-rebuild boot" "$calls"
  ! grep -q "systemd-run .*sudo nixos-rebuild" "$calls"
}

@test "--standalone with no target says it is ready" {
  run run_boot --standalone
  [ "$status" -eq 0 ]
  [[ "$output" == *"standalone ready"* ]]
  [[ "$output" == *"$(id -un) trusted"* ]]
}
@test "--help prints usage and exits 0" {
  run run_boot --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
  [[ "$output" == *"--rebind"* ]]
}

@test "--install installs the Home Manager release the flake pins" {
  tmp="$(mktemp -d)"
  cp "$repo/bootstrap.sh" "$tmp/"
  printf '{\n  inputs.home-manager.url = "github:nix-community/home-manager/release-25.05";\n}\n' > "$tmp/flake.nix"
  PATH="$stubs:$PATH" bash "$tmp/bootstrap.sh" --standalone --install || true
  grep -q "home-manager/archive/release-25.05.tar.gz" "$calls"
  rm -rf "$tmp"
}
