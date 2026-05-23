# modules/core/default.nix
{
  lib,
  self,
  inputs,
  ...
}: let
  # 1. Discover all .nix files in the hosts directory
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  hostFiles =
    lib.filterAttrs (
      n: t:
        t == "regular" && lib.hasSuffix ".nix" n
    )
    entries;

  # Import each host file, passing in necessary context
  hosts =
    lib.mapAttrs' (
      filename: _: let
        name = lib.removeSuffix ".nix" filename;
      in
        lib.nameValuePair name (import (hostsDir + "/${filename}") {inherit self inputs lib;})
    )
    hostFiles;

  # 2. Centralized Pkgs Instantiation (Preserves Unfree Overrides)
  mkPkgs = system: unfree:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };
  mkPkgsUnstable = system: unfree:
    import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };
in {
  # 3. Generate NixOS Configurations
  config.flake.nixosConfigurations = lib.mapAttrs (
    name: host: let
      pkgs = mkPkgs host.system (host.unfreeStable or []);
      pkgsUnstable = mkPkgsUnstable host.system (host.unfreeUnstable or []);
    in
      inputs.nixpkgs.lib.nixosSystem {
        inherit (host) system;
        inherit pkgs;
        modules = [
          self.flakeModules.nixos
          inputs.home-manager.nixosModules.home-manager
          (host.nixos or {})
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = {
                inherit inputs self pkgsUnstable;
                pkgsStable = pkgs;
              };
              users.${host.username} = lib.mkMerge [
                self.flakeModules.home-manager
                (host.home or {})
              ];
            };
          }
        ];
        specialArgs = {
          inherit inputs self pkgsUnstable;
          pkgsStable = pkgs;
          inherit (host) username;
        };
      }
  ) (lib.filterAttrs (_: h: h.isNixOS or true) hosts);

  # 4. Generate Standalone Home Manager Configurations
  config.flake.homeConfigurations = lib.mapAttrs (
    name: host: let
      pkgs = mkPkgs host.system (host.unfreeStable or []);
      pkgsUnstable = mkPkgsUnstable host.system (host.unfreeUnstable or []);
    in
      inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          self.flakeModules.home-manager
          (host.home or {})
          {
            home.username = host.username;
            home.homeDirectory = "/home/${host.username}";
            targets.genericLinux.enable = true;
          }
        ];
        extraSpecialArgs = {
          inherit inputs self pkgsUnstable;
          pkgsStable = pkgs;
        };
      }
  ) (lib.filterAttrs (_: h: !(h.isNixOS or true)) hosts);
}
