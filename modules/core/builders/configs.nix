# modules/core/builders/configs.nix
{
  lib,
  isDarwinPlatform,
  mkSystem,
  mkHome,
}: let
  buildConfigs = discoverHosts:
    lib.foldlAttrs (acc: name: host: let
      inherit (host) system unfreeStable unfreeUnstable;
      darwin = isDarwinPlatform system;
      isNixos = host.hasSystem && !darwin;
      isStandalone =
        if host ? standaloneHome
        then host.standaloneHome
        else darwin && host.homeFiles != [];
    in {
      nixos = acc.nixos // lib.optionalAttrs isNixos {${name} = mkSystem system name host.users false unfreeStable unfreeUnstable;};
      darwin = acc.darwin // lib.optionalAttrs (host.hasSystem && darwin) {${name} = mkSystem system name host.users isStandalone unfreeStable unfreeUnstable;};
      home =
        acc.home
        // lib.optionalAttrs (!darwin || host.homeFiles != []) (
          lib.listToAttrs (map (user: {
              name = "${user}@${name}";
              value = mkHome system name user isNixos unfreeStable unfreeUnstable;
            })
            host.users)
        );
    }) {
      nixos = {};
      darwin = {};
      home = {};
    }
    discoverHosts;
in {inherit buildConfigs;}
