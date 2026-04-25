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
    pkgs = pkgsUnstableFor system;
    pkgsStable = pkgsFor system;
  in
    (hmFor system).lib.homeManagerConfiguration {
      inherit pkgs; # nixpkgs for HM itself = unstable
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
        inherit self inputs pkgsStable;
        pkgsUnstable = pkgs;
        hostname = name;
      };
    };
in {inherit mkHome;}
