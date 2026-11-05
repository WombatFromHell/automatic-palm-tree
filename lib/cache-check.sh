#!/usr/bin/env bash
# Eval-only cache pre-flight: `nix run .#apps.<system>.cache-check -- <host>` from the repo.
# Exit 0 when every cache an enabled feature asks for is in that host's flakeCache.enable;
# exit 1 printing the host's own flakeCache warnings (modules/caches.nix writes the wording, so
# the fix is named here rather than paraphrased). Forcing the host config is the only cost - no
# build, which is the point on a host with little RAM.
set -euo pipefail

host="${1-}"
if [[ -z $host ]]; then
  echo "usage: cache-check <host>" >&2
  exit 2
fi

# The name goes into the expression only after it matches the flake's own NixOS configurations,
# so a typo on the command line cannot inject Nix code.
if ! nix eval --impure --expr 'builtins.attrNames (builtins.getFlake (toString ./.)).outputs.nixosConfigurations' |
  grep -q "\"$host\""; then
  echo "cache-check: unknown host '$host'" >&2
  exit 2
fi

warnings=$(nix eval --impure --raw --expr "
  let cfg = (builtins.getFlake (toString ./.)).outputs.nixosConfigurations.${host}.config;
  in builtins.concatStringsSep \"\\n\"
    (builtins.filter (w: builtins.substring 0 11 w == \"flakeCache:\") cfg.warnings)
")

if [[ -z $warnings ]]; then
  exit 0
fi

printf '%s\n' "$warnings" >&2
exit 1
