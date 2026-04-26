# modules/core/builders/system.nix
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

  mkSystem = system: name: users: let
    darwin = isDarwinPlatform system;

    pkgs = pkgsFor system;
    pkgsUnstable = pkgsUnstableFor system;

    evalSystem =
      if darwin
      then inputs.nix-darwin.lib.darwinSystem
      else inputs.nixpkgs.lib.nixosSystem;
  in
    evalSystem {
      inherit system;

      modules =
        [
          systemModules
          (hostsDir + "/${name}/system.nix")
          (platformModule system name)
        ]
        # Darwin requires explicit nixpkgs assignment
        ++ lib.optionals darwin [
          {nixpkgs.pkgs = pkgs;}
        ];

      # Pass args down to the 'system.nix'
      specialArgs = {
        inherit self inputs pkgsUnstable;
        pkgsStable = pkgs;
        username = lib.head users; # useful abstraction
      };
    };
in {inherit mkSystem;}
