# expect: declares 'aarch64-linux' in arches but no hash is pinned
# Fixture metadata.json, nothing fetched: a second architecture declared in `arches`
# with no hash must name that system, not surface later as a platform error in nixpkgs.
let
  s = import ../support.nix;
  pinMeta = import ../../lib/pin-meta.nix {inherit (s) lib;};
in
  pinMeta.pinnedSystems (builtins.fromJSON (builtins.readFile ../fixtures/pin-two-arch.json))
