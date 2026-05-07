{
  lib,
  inputs,
  self,
  hostsDir,
  systemModules,
}: let
  isDarwinPlatform = lib.hasSuffix "darwin";

  # Predicate builder: checks if a package's name (pname > name) is in the unfree list.
  mkAllowUnfree = unfreeList: pkg: builtins.elem (lib.getName pkg) unfreeList;

  pkgsFor = system: unfreeList:
    import (
      if isDarwinPlatform system
      then inputs.nixpkgs-darwin
      else inputs.nixpkgs
    ) {
      inherit system;
      config.allowUnfreePredicate = mkAllowUnfree unfreeList;
    };

  pkgsUnstableFor = system: unfreeList:
    import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfreePredicate = mkAllowUnfree unfreeList;
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
