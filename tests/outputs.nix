# Output suite: the shape of flake.outputs. Every check forces a value or a
# derivation *reference*, never a build. ~14s.
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

  checks = [
    (ck "the flake exposes only nixosConfigurations, homeConfigurations and checks"
      (lib.attrNames out == ["checks" "homeConfigurations" "nixosConfigurations"]))
    (ck "checks are keyed by supported system" (lib.attrNames out.checks == ["x86_64-linux"]))
    (ck "every configuration gets a check named after it"
      (lib.attrNames out.checks.x86_64-linux == expectedChecks))
    (ck "nixosConfigurations covers exactly the isNixOS hosts"
      (lib.attrNames out.nixosConfigurations == (lib.filter (h: hosts.${h}.isNixOS) (lib.attrNames hosts))))
    (ck "homeConfigurations are keyed user@host"
      (lib.attrNames out.homeConfigurations == ["josh@methyl-bazzite"]))
    (ck "a nixos check is the system toplevel derivation"
      (lib.all (h: lib.isDerivation out.checks.x86_64-linux."nixos-${h}") (lib.attrNames out.nixosConfigurations)))
    (ck "a home check is the activation package derivation"
      (lib.all (k: lib.isDerivation out.checks.x86_64-linux."home-${k}") (lib.attrNames out.homeConfigurations)))
    (ck "host facts reach the configuration through builders.nix"
      (lib.all (h: out.nixosConfigurations.${h}.config.flakeHost.name == h) (lib.attrNames out.nixosConfigurations)))
  ];
in suite "outputs" checks
