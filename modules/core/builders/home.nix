# modules/core/builders/home.nix
{
  lib,
  inputs,
  self,
  hostsDir,
  isDarwinPlatform,
  pkgsFor,
  pkgsUnstableFor,
}: let
  hmFor = system:
    if isDarwinPlatform system
    then inputs.home-manager-darwin
    else inputs.home-manager;

  mkHome = system: name: user: let
    pkgs = pkgsFor system; # stable nixpkgs by default
    pkgsUnstable = pkgsUnstableFor system;
  in
    (hmFor system).lib.homeManagerConfiguration {
      inherit pkgs; # HM uses stable for its internals
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
        inherit self inputs pkgsUnstable;
        hostname = name;
      };
    };
in {inherit mkHome;}
