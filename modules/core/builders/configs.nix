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
      isNixos = host.hasSystem && !darwin; # we know it's NixOS like this
    in {
      nixos = acc.nixos // lib.optionalAttrs isNixos {${name} = mkSystem system name host.users;};
      darwin = acc.darwin // lib.optionalAttrs (host.hasSystem && darwin) {${name} = mkSystem system name host.users;};
      home =
        acc.home
        // lib.listToAttrs (map (user: {
            name = "${user}@${name}";
            value = mkHome system name user isNixos; # let home-manager know
          })
          host.users);
    }) {
      nixos = {};
      darwin = {};
      home = {};
    }
    discoverHosts;
in {inherit buildConfigs;}
