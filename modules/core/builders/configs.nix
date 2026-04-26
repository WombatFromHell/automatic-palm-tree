# modules/core/builders/configs.nix
{
  lib,
  isDarwinPlatform,
  mkSystem,
  mkHome,
}: let
  buildConfigs = discoverHosts:
    lib.foldlAttrs (acc: name: host: let
      inherit (host) system;
      darwin = isDarwinPlatform system;
      isNixos = host.hasSystem && !darwin;
    in {
      nixos = acc.nixos // lib.optionalAttrs isNixos {${name} = mkSystem system name host.users false;};
      darwin = acc.darwin // lib.optionalAttrs (host.hasSystem && darwin) {${name} = mkSystem system name host.users host.standaloneHome;};
      home =
        acc.home
        // lib.optionalAttrs (!darwin || host.standaloneHome) (
          lib.listToAttrs (map (user: {
              name = "${user}@${name}";
              value = mkHome system name user isNixos;
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
