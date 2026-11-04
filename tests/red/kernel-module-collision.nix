# expect: pins boot.kernelPackages twice
# A host that lists a kernel feature AND pins the kernel in its own nixosModules file.
# The module system would report "defined multiple times" with two store paths and no
# host name; this guard wants the host and both writers named at the point the host
# record is still in hand. Fixture module only - nothing is built or fetched.
let
  s = import ../support.nix;
  host =
    (s.fixtureHost true ["nixos-cachyos"] {})
    // {
      name = "kernelhost";
      nixosModules = [../fixtures/kernelhost/nixos.nix];
    };
in
  (s.builders.buildNixosConfigurations {kernelhost = host;}).kernelhost.config.flakeHost
