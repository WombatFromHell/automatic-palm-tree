{
  lib,
  inputs,
  self,
  hostsDir,
  isDarwinPlatform,
  pkgsFor,
}: let
  mkHome = system: name: user: let
    pkgs = pkgsFor system;
  in
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        (hostsDir + "/${name}/home-${user}.nix")
        {
          home.username = lib.mkDefault user;
          home.homeDirectory = lib.mkDefault (
            if isDarwinPlatform system
            then "/Users/${user}"
            else "/home/${user}"
          );
          nixpkgs.system = lib.mkDefault system;
        }
      ];
      extraSpecialArgs = {
        inherit self inputs;
        hostname = name;
      };
    };
in {inherit mkHome;}
