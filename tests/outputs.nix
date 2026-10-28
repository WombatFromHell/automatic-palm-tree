# Output suite: the shape of flake.outputs. Every check reads attribute *names*, never a value or
# a derivation, so the whole suite stays cheap (~0.4GB). A check that forces a derivation would
# evaluate that host's toplevel: even `x.type` on a derivation costs ~700MB, because the
# derivation attrset is merged. Proving the derivations themselves is `nix flake check`'s job —
# it builds them — and that is out of this suite's memory budget on a RAM-constrained box.
# ~8s.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;
  out = s.flake.outputs;
  hosts = s.hosts.discoveredHosts;

  # Derived, not hardcoded: the check set must mirror the configurations.
  # attrNames is sorted, so the derived list is sorted too.
  expectedChecks =
    lib.sort (a: b: a < b)
    ((map (h: "nixos-${h}") (lib.attrNames out.nixosConfigurations))
      ++ (map (k: "home-${k}") (lib.attrNames out.homeConfigurations)));

  # Derived from the records, mirroring builders.nix: only a standalone host
  # (isNixOS = false) produces homeConfigurations, keyed user@host.
  expectedHomeKeys =
    lib.sort (a: b: a < b)
    (lib.concatLists (map (h: map (u: "${u}@${h.name}") h.hmUsernames) (lib.filter (h: !h.isNixOS) (lib.attrValues hosts))));

  checks = [
    (ck "the flake exposes only nixosConfigurations, homeConfigurations and checks"
      (lib.attrNames out == ["checks" "homeConfigurations" "nixosConfigurations"]))
    (ck "checks are keyed by supported system" (lib.attrNames out.checks == ["x86_64-linux"]))
    (ck "every configuration gets a check named after it"
      (lib.attrNames out.checks.x86_64-linux == expectedChecks))
    (ck "nixosConfigurations covers exactly the isNixOS hosts"
      (lib.attrNames out.nixosConfigurations == (lib.filter (h: hosts.${h}.isNixOS) (lib.attrNames hosts))))
    (ck "homeConfigurations are keyed user@host"
      (lib.attrNames out.homeConfigurations == expectedHomeKeys))
  ];
in
  suite "outputs" checks
