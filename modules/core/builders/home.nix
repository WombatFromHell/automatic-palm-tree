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

  mkHome = system: name: user: isNixos: let
    # Accept the new argument
    pkgs = pkgsFor system;
    pkgsUnstable = pkgsUnstableFor system;
    darwin = isDarwinPlatform system;
  in
    (hmFor system).lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        (hostsDir + "/${name}/home-${user}.nix")
        {
          home.username = lib.mkDefault user;
          home.homeDirectory = lib.mkDefault (
            if darwin
            then "/Users/${user}"
            else "/home/${user}"
          );
          nixpkgs.system = lib.mkDefault system;

          targets.genericLinux.enable = lib.mkDefault (!isNixos && !darwin);
        }
      ];
      extraSpecialArgs = {
        inherit self inputs pkgsUnstable;
        pkgsStable = pkgs;
        hostname = name;
      };
    };
in {inherit mkHome;}
