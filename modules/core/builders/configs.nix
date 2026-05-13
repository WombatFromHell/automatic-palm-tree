{
  lib,
  isDarwinPlatform,
  discoverHosts,
  mkSystem,
  mkHome,
}: let
  buildConfigs = let
    inherit (lib) foldlAttrs optionalAttrs listToAttrs map;
  in
    foldlAttrs (acc: name: host: let
      inherit (host) system unfreeStable unfreeUnstable;
      darwin = isDarwinPlatform system;
      isNixos = host.hasSystem && !darwin;
      isStandalone = host.standaloneHome or (darwin && host.homeFiles != []);
    in {
      nixos =
        acc.nixos
        // optionalAttrs isNixos {
          ${name} = mkSystem {
            inherit system name;
            inherit (host) users unfreeStable unfreeUnstable;
          };
        };
      darwin =
        acc.darwin
        // optionalAttrs (host.hasSystem && darwin) {
          ${name} = mkSystem {
            inherit system name;
            inherit (host) users unfreeStable unfreeUnstable;
            standaloneHome = isStandalone;
          };
        };
      home =
        acc.home
        // optionalAttrs (!darwin || host.homeFiles != []) (
          listToAttrs (map (user: {
              name = "${user}@${name}";
              value = mkHome {inherit system name user isNixos unfreeStable unfreeUnstable;};
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
