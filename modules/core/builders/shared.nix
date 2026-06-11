{
  lib,
  self,
  inputs,
}: let
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self pkgsLib;};
in {
  inherit pkgsLib featuresLib;

  hostHmModules = host:
    lib.flatten [
      (host.modules.home or [])
      (host.modules.shared or [])
    ];

  # Collect and deduplicate all unfree package names for a host.
  # featureDataList is a list of resolved feature data attrsets, each with a .unfree list.
  collectUnfree = host: featureDataList: userModulePaths:
    lib.unique (lib.flatten (
      [(host.unfree or [])]
      ++ (map (fd: fd.unfree) featureDataList)
      ++ [(pkgsLib.extractUnfree pkgsLib.mkUnfreeOptionsModule userModulePaths).config.unfree]
    ));

  # Resolve features for a platform, pre-filtering to those with a module for that platform
  resolveFeatures = host: platform:
    featuresLib.resolve
    (lib.filter
      (f:
        featuresLib.discoveredFeatures ? ${f}
        && featuresLib.discoveredFeatures.${f} ? ${platform})
      (host.features or []))
    platform;
}
