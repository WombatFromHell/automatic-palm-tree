# Home Manager-only host builder. consumes config.discoveredHosts and maps
# each non-NixOS host to homeConfigurations (keyed as user@host).
#
# Host context (pkgsStable with homeOverlays, pkgsUnstable, unfree, modules)
# is pre-computed during discovery — builders read it from the host entry.
{
  self,
  lib,
  config,
  inputs,
  ...
}: let
  builderHelpers = import ../../lib/builder-helpers.nix {inherit lib self;};

  hmHosts = lib.filterAttrs (_: h: !(h.isNixOS or false)) config.discoveredHosts;

  mkHomeConfig = host: user: let
    inherit (host) pkgsStable; # pre-built with homeOverlays (including nixgl)

    baseModule = {
      imports = [
        (builderHelpers.mkUserHomeModule {
          ctx = host; # host carries homeModules from pre-built context
          inherit user host;
        })
        {targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);}
      ];
      # Overlays are evaluated via 'overlays.nix' files during discovery
    };
  in
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsStable;
      modules = lib.flatten [
        self.flakeModules.nix-settings
        baseModule
      ];

      extraSpecialArgs = {
        inherit pkgsStable;
        inherit (host) pkgsUnstable;
        inherit inputs self;
        hostConfig = host;
      };
    };

  allHomeConfigs =
    lib.foldl' lib.recursiveUpdate {}
    (lib.mapAttrsToList
      (_: h:
        lib.listToAttrs
        (map
          (user: lib.nameValuePair "${user}@${h.name}" (mkHomeConfig h user))
          h.hmUsernames))
      hmHosts);
in {
  imports = [../discovery.nix];
  flake.homeConfigurations = allHomeConfigs;
}
