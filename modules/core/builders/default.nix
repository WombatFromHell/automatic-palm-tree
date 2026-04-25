{
  lib,
  inputs,
  self,
  hostsDir,
  systemModules,
}: let
  isDarwinPlatform = lib.hasSuffix "darwin";

  pkgsFor = system:
    import (
      if isDarwinPlatform system
      then inputs.nixpkgs-darwin
      else inputs.nixpkgs
    ) {
      inherit system;
      config.allowUnfree = true;
    };

  pkgsUnstableFor = system:
    import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };

  system = import ./system.nix {
    inherit lib inputs self hostsDir systemModules isDarwinPlatform pkgsFor pkgsUnstableFor;
  };
  home = import ./home.nix {
    inherit lib inputs self hostsDir isDarwinPlatform pkgsFor pkgsUnstableFor;
  };
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
