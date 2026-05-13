{
  lib,
  inputs,
  self,
  isDarwinPlatform,
  pkgsFor,
  pkgsUnstableFor,
}: let
  hmFor = system:
    if isDarwinPlatform system
    then inputs.home-manager-darwin
    else inputs.home-manager;

  mkHome = {
    system,
    name,
    user,
    isNixos,
    unfreeStable ? [],
    unfreeUnstable ? [],
  }: let
    pkgs = pkgsFor system unfreeStable;
    pkgsUnstable = pkgsUnstableFor system unfreeUnstable;
    darwin = isDarwinPlatform system;
  in
    (hmFor system).lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        (self + /hosts/${name}/home-${user}.nix)
        {
          home.username = lib.mkDefault user;
          home.homeDirectory = lib.mkForce (
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
