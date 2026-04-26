{
  lib,
  inputs,
  self,
  hostsDir,
  systemModules,
  isDarwinPlatform,
  pkgsFor,
  pkgsUnstableFor,
}: let
  platformModule = system: name: {
    networking.hostName = lib.mkDefault name;
    nixpkgs.hostPlatform = lib.mkDefault system;
  };

  mkSystem = system: name: users: standaloneHome: let
    darwin = isDarwinPlatform system;
    pkgs = pkgsFor system;
    pkgsUnstable = pkgsUnstableFor system;

    automaticHomeManagerModule = lib.optionalAttrs (darwin && !standaloneHome) (
      import ./home-darwin.nix {
        inherit lib inputs self hostsDir name users pkgs pkgsUnstable;
      }
    );

    evalSystem =
      if darwin
      then inputs.nix-darwin.lib.darwinSystem
      else inputs.nixpkgs.lib.nixosSystem;
  in
    evalSystem {
      inherit system;

      modules = lib.flatten [
        systemModules
        (hostsDir + "/${name}/system.nix")
        (platformModule system name)
        (lib.optionals darwin [
          {nixpkgs.pkgs = pkgs;}
          inputs.home-manager-darwin.darwinModules.home-manager
          automaticHomeManagerModule
        ])
      ];

      specialArgs = {
        inherit self inputs pkgsUnstable;
        pkgsStable = pkgs;
        username = lib.head users;
      };
    };
in {inherit mkSystem;}
