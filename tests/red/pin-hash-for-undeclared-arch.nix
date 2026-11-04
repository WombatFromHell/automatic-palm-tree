# expect: pins 'aarch64-linux' in hashes but arches declares only
# Fixture metadata.json, nothing fetched: a hash pinned for a system `arches` never
# declared is a key nobody can resolve an asset URL for, so the boundary names both lists.
let
  s = import ../support.nix;
  pinMeta = import ../../lib/pin-meta.nix {inherit (s) lib;};
in
  pinMeta.pinnedSystems (builtins.fromJSON (builtins.readFile ../fixtures/pin-hash-only-arch.json))
