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

  hmHosts = lib.filterAttrs (_: hostEntry: !(hostEntry.isNixOS or false)) config.discoveredHosts;

  mkHomeConfig = host: user: let
    inherit (host) pkgsStable; # pre-built with homeOverlays (including nixgl)

    baseModule = {
      imports = [
        (builderHelpers.mkUserHomeModule {
          inherit user host;
        })
        {targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);}
      ];
      # Overlays are evaluated via 'overlays.nix' files during discovery
    };
  in
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsStable;
      modules = [
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

  allHomeConfigs = builtins.listToAttrs (
    lib.concatLists (lib.mapAttrsToList (_: hostEntry:
      map (user: lib.nameValuePair "${user}@${hostEntry.name}" (mkHomeConfig hostEntry user))
        hostEntry.hmUsernames
    ) hmHosts)
  );
in {
  imports = [../discovery.nix];
  flake.homeConfigurations = allHomeConfigs;
}
