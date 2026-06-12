{
  lib,
  self,
  inputs,
}: let
  pkgsLib = import ../pkgs.nix {inherit lib;};
  featuresLib = import ../features.nix {inherit lib self pkgsLib;};

  resolveHostModules = host: platform:
    lib.flatten [
      (host.modules.${platform} or [])
      (host.modules.shared or [])
    ];
in {
  inherit pkgsLib featuresLib resolveHostModules;

  hostHmModules = host: resolveHostModules host "home";

  # Collect and deduplicate all unfree package names for a host.
  # featureDataList is a list of resolved feature data attrsets, each with a .unfree list.
  collectUnfree = host: featureDataList: userModulePaths:
    lib.unique (lib.flatten (
      [(host.unfree or [])]
      ++ (map (fd: fd.unfree) featureDataList)
      ++ [(pkgsLib.extractUnfree pkgsLib.mkUnfreeOptionsModule userModulePaths).config.unfree]
    ));

  # Resolve features for a platform. Unknown features are passed through to
  # featuresLib.resolve which throws a descriptive error. Known features that
  # lack a module for the target platform are silently skipped (e.g. HM-only
  # features in a NixOS host's feature list).
  resolveFeatures = host: platform:
    featuresLib.resolve
    (builtins.filter
      (f:
        if featuresLib.discoveredFeatures ? ${f}
        then featuresLib.discoveredFeatures.${f} ? ${platform}
        else true) # let unknown through so resolve can throw
      
      (host.features or []))
    platform;

  # Accumulate all per-user home module paths for a host.
  # Collects modules across *all* users, which means unfree extraction sees every
  # user's declarations regardless of which user is being built. Conservative by
  # design: allows more packages, not fewer.
  perUserModulePaths = host:
    lib.concatLists (lib.attrValues (host.modules.perUser or {}));

  # Build the unstable package set for a host
  mkUnstablePkgs = host: allUnfree:
    pkgsLib.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];

  # Build the home-manager module for a single user
  mkUserHomeModule = {
    lib,
    pkgsLib,
    self,
    user,
    homeFeaturesData,
    hostHmModules,
    perUserMod,
  }: {
    imports = lib.flatten [
      homeFeaturesData.modules
      hostHmModules
      perUserMod
      pkgsLib.mkUnfreeOptionsModule
      self.flakeModules.home-manager
    ];
    home.username = user;
    home.homeDirectory = "/home/${user}";
  };
}
