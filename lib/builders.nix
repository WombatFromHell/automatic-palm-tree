# Config builders — NixOS + Home Manager system builders and their helpers.
#
# Consumes the feature machinery (lib/features.nix) for path resolution and the
# feature options module. `mkUserHomeModule` is internal (wired by both
# builders); the three public entries are re-exported by lib/default.nix.
{
  lib,
  self,
  inputs,
  features,
  ...
}: let
  inherit (features) featureOptionsModule resolveFeaturePaths;

  # ── Home Manager user module ──
  # Imported by the host's NixOS config (via buildNixosConfigurations) and by
  # standalone homeConfigurations. Wires the user's home features +
  # homeModules into a Home Manager module.
  mkUserHomeModule = {
    user,
    host,
  }: let
    homeFeaturePaths = resolveFeaturePaths host.features "home";
    userHomeModules =
      if builtins.hasAttr user host.homeModules
      then host.homeModules.${user}
      else [];
  in {
    imports = lib.flatten [
      homeFeaturePaths
      userHomeModules
      featureOptionsModule
      (self + /modules/defaults/home-manager.nix)
    ];
    _module.args.user = user;
  };

  # ── helper: emit a warning for admin users on non-NixOS hosts ──
  checkAdminWarning = name: cfg: let
    adminNames = lib.filter (n: cfg.users.${n}.isAdmin) (builtins.attrNames cfg.users);
  in
    lib.optionals (!cfg.isNixOS && adminNames != [])
    ["${name}: 'isNixOS = false', but users.${lib.concatStringsSep ", " adminNames}.isAdmin = true! This is a no-op on standalone home-manager hosts."];

  # ── helper: common special args for host modules ──
  hostArgs = host: {
    inherit inputs self;
    hostConfig = host;
  };

  # ── helper: Home Manager wiring for NixOS hosts ──
  mkHomeManagerModule = {host, ...}: {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = {inherit (host) pkgsUnstable;} // hostArgs host;
      users =
        lib.genAttrs host.hmUsernames (user:
          mkUserHomeModule {inherit user host;});
    };
  };

  # ── NixOS configuration builder ──
  buildNixosConfigurations = hostsWithPkgs: let
    nixosHosts = lib.filterAttrs (_: h: h.isNixOS) hostsWithPkgs;
  in
    lib.mapAttrs (
      _name: host:
        inputs.nixpkgs.lib.nixosSystem {
          modules = lib.flatten [
            # Feature modules for the NixOS platform
            {
              imports =
                resolveFeaturePaths host.features "nixos"
                ++ [featureOptionsModule];
            }
            # Nix daemon settings
            (self + /modules/nix-settings.nix)
            # Common NixOS defaults + user defaults (merged)
            (self + /modules/defaults/nixos.nix)
            # Host-local modules
            host.nixosModules
            # Home Manager integration
            inputs.home-manager.nixosModules.home-manager
            # Inline: unfree pkgs, pkgsUnstable, warnings
            ({lib, ...}: {
              nixpkgs.config.allowUnfree = true;
              warnings = host.warnings or [];
              _module.args.pkgsUnstable = host.pkgsUnstable;
            })
            # Home Manager wiring
            (mkHomeManagerModule {inherit host;})
          ];
          specialArgs = hostArgs host;
        }
    )
    nixosHosts;

  # ── Home Manager configuration builder ──
  buildHomeConfigurations = hostsWithPkgs: let
    hmHosts = lib.filterAttrs (_: h: !h.isNixOS) hostsWithPkgs;

    mkHomeConfigsForHost = host: let
      mkHomeConfig = user:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit (host) pkgs;
          modules = [
            (self + /modules/nix-settings.nix)
            (mkUserHomeModule {inherit user host;})
            {targets.genericLinux.enable = lib.mkDefault true;}
            {warnings = host.warnings or [];}
          ];
          extraSpecialArgs = {inherit (host) pkgsUnstable;} // hostArgs host;
        };
    in
      map (user: lib.nameValuePair "${user}@${host.name}" (mkHomeConfig user)) host.hmUsernames;
  in
    builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: mkHomeConfigsForHost) hmHosts));
in {
  inherit
    buildNixosConfigurations
    buildHomeConfigurations
    checkAdminWarning
    ;
}
