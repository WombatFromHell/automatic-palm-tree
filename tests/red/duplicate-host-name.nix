# expect: Two host definitions
# hosts/x.nix beside hosts/x/default.nix would silently shadow one another.
let
  s = import ../support.nix;
in
  (s.hostsAt ../fixtures/duplicate).discoveredHosts.dup
