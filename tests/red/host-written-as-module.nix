# expect: host record
# A host file is a record of facts, not a NixOS module; a stray `boot.*` line
# must be rejected with the loader's own guidance.
let
  s = import ../support.nix;
in
  (s.hostsAt ../fixtures/reject).discoveredHosts.bad
