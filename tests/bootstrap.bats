#!/usr/bin/env bats
# bootstrap.sh against PATH stubs: argv and exit codes only. No root, no real /nix, no curl, no eval.
load helpers

# nix answers only the two calls bootstrap makes: `store info` and the registry eval.
# Trust and daemon reachability are state files in the stub dir, not env vars on the test line: a
# value read from the environment makes the outcome depend on what the surrounding process happens
# to carry, which is how the trust test failed once inside tests/run.sh and never standalone.
setup() {
  harness_stub_dir
  printf '1\n' >"$stubs/trusted"
  printf '0\n' >"$stubs/nix_info_exit"
  stub nix <<EOF
#!/usr/bin/env bash
echo "nix \$*" >> "$calls"
if [ "\$1 \$2" = "store info" ]; then
  if [ "\$(cat $stubs/nix_info_exit)" != 0 ]; then echo "error: cannot connect to the nix daemon" >&2; exit 1; fi
  printf 'Trusted: %s\n' "\$(cat $stubs/trusted)" >&2
  exit 0
fi
case "\$6" in
  substituters) printf 'https://cache.example/x 1\n' ;;
  trustedPublicKeys) printf 'cache.example:2\n' ;;
  *) exit 1 ;;
esac
EOF
  for tool in sudo home-manager nixos-rebuild nix-channel nix-shell systemd-run; do
    env_name="${tool^^}"
    env_name="${env_name//-/_}"
    stub "$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit \${${env_name}_EXIT:-0}
EOF
  done
}

run_boot() { PATH="$stubs:$PATH" bash "$repo/bootstrap.sh" "$@"; }

@test "bare host: sudo nixos-rebuild boot with the bootloader flag and the registry caches" {
  run run_boot methyl
  [ "$status" -eq 0 ]
  assert_call "sudo nixos-rebuild boot --install-bootloader --flake .*#methyl"
  assert_call "--option extra-substituters https://cache.example/x 1"
  assert_call "--option extra-trusted-public-keys cache.example:2"
}

@test "user@host: home-manager switch, caches injected" {
  run run_boot josh@example.test
  [ "$status" -eq 0 ]
  assert_call "home-manager switch --flake .*#josh@example.test"
  assert_call "--option extra-substituters"
}

@test "--standalone refuses a bare host: it has no NixOS config to rebuild" {
  run run_boot --standalone methyl
  [ "$status" -eq 2 ]
  [[ $output == *"--standalone target must be"* ]]
}

@test "--rebind on a box that already has Nix is refused, not dropped" {
  run run_boot --standalone --rebind=/mnt/data1/nix josh@example.test
  [ "$status" -eq 2 ]
  [[ $output == *"fresh install"* ]]
}

@test "--rebind= with no directory is refused" {
  run run_boot --standalone --rebind= josh@example.test
  [ "$status" -eq 2 ]
  [[ $output == *"--rebind needs a directory"* ]]
}

@test "--standalone cannot report success when trust did not take effect" {
  printf '0\n' >"$stubs/trusted"
  run run_boot --standalone
  [ "$status" -eq 2 ]
  assert_out "still not a trusted nix user"
  # The untrusted branch has to have been taken, not just failed somewhere else.
  assert_call "sudo tee -a /etc/nix/nix.custom.conf"
}

@test "a trust write into a sudo that never reads stdin still reports the failure" {
  printf '0\n' >"$stubs/trusted"
  # A username longer than the 64K pipe buffer makes the write block, so a stub that exits
  # without reading stdin is guaranteed to SIGPIPE the shell -- the shape tests/run.sh reached
  # intermittently as status 141: the bootstrap died mid-way, no restart, no message.
  stub id <<'EOF'
#!/usr/bin/env bash
head -c 131072 /dev/zero | tr '\0' 'x'
EOF
  run run_boot --standalone
  [ "$status" -eq 2 ]
  assert_out "still not a trusted nix user"
  assert_call "sudo systemctl restart nix-daemon.service"
  assert_no_out "standalone ready"
}

@test "an untrusted switch names the daemon, not just the user" {
  printf '0\n' >"$stubs/trusted"
  run run_boot josh@example.test
  [ "$status" -eq 2 ]
  assert_out "nix daemon"
}

@test "a daemon that does not answer is not reported as an untrusted user" {
  printf '1\n' >"$stubs/nix_info_exit"
  run run_boot josh@example.test
  [ "$status" -eq 2 ]
  assert_out "nix store info"
}
@test "--rebind reaches the installer as --persistence" {
  # The installer path only runs where Nix is genuinely absent; this box has a receipt.
  [ -f /nix/receipt.json ] && skip "/nix/receipt.json present — installer path cannot run here"
  rm "$stubs/nix"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\nprintf "#!/bin/sh\\nexit 0\\n"\n' "$calls" >"$stubs/curl"
  chmod +x "$stubs/curl"
  PATH="$stubs:/usr/bin:/bin" bash "$repo/bootstrap.sh" --standalone --rebind=/mnt/data1/nix || true
  assert_call "install ostree --enable-flakes --persistence /mnt/data1/nix"
}

@test "a failing systemd-run still runs the rebuild, unwrapped" {
  SYSTEMD_RUN_EXIT=1 run run_boot methyl
  [ "$status" -eq 0 ]
  assert_call "^sudo nixos-rebuild boot"
  assert_no_call "systemd-run .*sudo nixos-rebuild"
}

@test "--standalone with no target says it is ready" {
  run run_boot --standalone
  [ "$status" -eq 0 ]
  [[ $output == *"standalone ready"* ]]
  [[ $output == *"$(id -un) trusted"* ]]
}
@test "--help prints usage and exits 0" {
  run run_boot --help
  [ "$status" -eq 0 ]
  [[ $output == *"usage:"* ]]
  [[ $output == *"--rebind"* ]]
}

@test "--install installs the Home Manager release the flake pins" {
  tmp="$(mktemp -d)"
  cp "$repo/bootstrap.sh" "$tmp/"
  printf '{\n  inputs.home-manager.url = "github:nix-community/home-manager/release-25.05";\n}\n' >"$tmp/flake.nix"
  PATH="$stubs:$PATH" bash "$tmp/bootstrap.sh" --standalone --install || true
  assert_call "home-manager/archive/release-25.05.tar.gz"
  rm -rf "$tmp"
}
