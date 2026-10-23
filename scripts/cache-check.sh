#!/usr/bin/env bash
# cache-check — pre-flight for a switch: which paths will be substituted, which must be built.
#
# Eval only (no builds, no `nix build`), plus narinfo HEADs against the host's own declared
# substituters. A store path is substitutable iff some cache serves <hash>.narinfo.
#
#   nix run .#cache-check -- propyl
#
# Keys matter as much as urls: a cache whose key is not in the *live* /etc/nix/nix.conf cannot be
# used from this machine yet, which is exactly what the first switch after a registry change hits.
set -euo pipefail

host="${1:-propyl}"
root="$(cd "$(dirname "$0")/.." && pwd)"
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT

# Composite probe: dashed attrs and derivation lists are not reachable by CLI path traversal.
cat >"$probe" <<EOF
let
  f = builtins.getFlake "${root}";
  lib = f.inputs.nixpkgs.lib;
  c = f.nixosConfigurations.${host};
  paths =
    [ c.config.boot.kernelPackages.kernel.outPath
      c.config.hardware.kait2en.firmware.package.outPath or ""
    ]
    ++ map (m: m.outPath) c.config.boot.extraModulePackages;
  lines =
    map (p: "path " + p) (builtins.filter (p: p != "") paths)
    ++ map (u: "sub " + u) (c.config.nix.settings.extra-substituters or [])
    ++ map (w: "warn " + w) c.config.warnings;
in lib.concatStringsSep "\n" lines + "\n"
EOF

out="$(nix eval --impure --allow-dirty --raw --file "$probe")"

paths=()
subs=()
while read -r kind value; do
  case "$kind" in
    path) paths+=("$value") ;;
    sub) subs+=("$value") ;;
    warn) echo "warning: $value" ;;
  esac
done <<<"$out"

if [ ${#subs[@]} -eq 0 ]; then
  echo "$host: no substituters declared (flakeCache.enable = []) — everything is built locally"
  exit 0
fi

substitutable=0
for p in "${paths[@]}"; do
  hash="${p#/nix/store/}"; hash="${hash%%-*}"
  hit=""
  for u in "${subs[@]}"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$u/${hash}.narinfo" || echo 000)"
    if [ "$code" = "200" ]; then hit="$u"; break; fi
  done
  if [ -n "$hit" ]; then
    substitutable=$((substitutable + 1))
    echo "  substitute  ${p##*/}  <- $hit"
  else
    echo "  LOCAL BUILD ${p##*/}  (no cache serves it)"
  fi
done

echo "$host: $substitutable of ${#paths[@]} paths substitutable; $(( ${#paths[@]} - substitutable )) built locally"
echo "note: a cache is only usable once its key is in the live /etc/nix/nix.conf, so the switch"
echo "      that ships a new key still builds locally (nix.extraOptions = fallback = true)."
