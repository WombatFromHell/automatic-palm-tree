{
  lib,
  inputs,
  self,
  hostsDir,
  systemModules,
}: let
  isDarwinPlatform = lib.hasSuffix "darwin";
  pkgsFor = system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [inputs.lix-module.overlays.default];
    };

  system = import ./system.nix {inherit lib inputs self hostsDir systemModules isDarwinPlatform;};
  home = import ./home.nix {inherit lib inputs self hostsDir isDarwinPlatform pkgsFor;};
  configs = import ./configs.nix {
    inherit lib isDarwinPlatform;
    inherit (system) mkSystem;
    inherit (home) mkHome;
  };
in {
  inherit (system) mkSystem;
  inherit (home) mkHome;
  inherit (configs) buildConfigs;
}
