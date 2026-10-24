# Config builders — NixOS + Home Manager system builders and their helpers.
#
# Consumes the feature machinery (lib/features.nix) for path resolution and the
# feature options module. `mkUserHomeModule` is internal (wired by both
# builders); the two public entries are re-exported by lib/default.nix.
{
  lib,
  self,
  inputs,
  features,
  flakeHostOptions,
  ...
}: let
  inherit (features) resolveFeaturePaths;

  # Options every feature module may read, applied to both namespaces below.
  featureOptionsModule = import (self + /modules/feature-options.nix);

  # Stage narrowing for the two-stage bootstrap (see lib/stages.nix).
  stages = import (self + /lib/stages.nix) {};

  # Host facts are declared once here and set per host, so consumers read
  # config.flakeHost instead of an untyped injected record. The value is the host
  # record narrowed to flakeHostOptions: a fact the schema declares but the record
  # lacks is a loud missing-attribute error, an extra attribute is ignored.
  mkHostFactsModule = host:
    import (self + /modules/host-facts.nix) {
      inherit lib flakeHostOptions;
      flakeHost = lib.getAttrs (lib.attrNames flakeHostOptions) host;
    };

  # ── Home Manager user module ──
  # Imported by the host's NixOS config (via buildNixosConfigurations) and by
  # standalone homeConfigurations. Wires the user's home features +
  # homeModules into a Home Manager module.
  mkUserHomeModule = {
    user,
    host,
  }: let
    homeFeaturePaths = resolveFeaturePaths host.features "home";
    userHomeModules = host.homeModules.${user} or [];
  in {
    imports =
      homeFeaturePaths
      ++ userHomeModules
      ++ [
        featureOptionsModule
        (self + /modules/defaults/home-manager.nix)
        (mkHostFactsModule host)
      ];
    home.username = lib.mkDefault user;
    home.homeDirectory = lib.mkDefault "/home/${user}";
  };

  # ── helper: special args for host modules (four features build module paths from inputs) ──
  # fsLib reaches every module via specialArgs: nixosSystem (:103), HM integration (:60)
  # and standalone HM configs (:~122), including generated hardware-configuration.nix.
  inputArgs = {
    inherit inputs;
    fsLib = import (self + /lib/filesystems.nix) {inherit lib;};
  };

  # ── helper: Home Manager wiring for NixOS hosts ──
  mkHomeManagerModule = host: {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = inputArgs;
      users =
        lib.genAttrs host.hmUsernames (user:
          mkUserHomeModule {inherit user host;});
    };
  };

  # ── NixOS configuration builder ──
  buildNixosConfigurations = hostsWithPkgs: let
    nixosHosts = lib.filterAttrs (_: h: h.isNixOS) hostsWithPkgs;

    mkConfig = host:
      inputs.nixpkgs.lib.nixosSystem {
        modules = lib.flatten [
          # Substitution first: caches.nix owns every url/key the feature modules below gate on.
          (self + /modules/caches.nix)
          # Feature modules for the NixOS platform
          {
            imports =
              resolveFeaturePaths host.features "nixos"
              ++ [featureOptionsModule];
          }
          # Host facts (config.flakeHost)
          (mkHostFactsModule host)
          # Nix daemon settings
          (self + /modules/nix-settings.nix)
          # Common NixOS defaults + user defaults (merged)
          (self + /modules/defaults/nixos.nix)
          # Host-local modules
          host.nixosModules
          # Home Manager integration
          inputs.home-manager.nixosModules.home-manager
          # Inline: one package set per host
          {
            nixpkgs.pkgs = host.pkgs;
          }
          # Home Manager wiring
          (mkHomeManagerModule host)
        ];
        specialArgs = inputArgs;
      };

    # Stage 1 of the two-stage bootstrap: `<host>-boot` for hosts that declare bootFeatures.
    # Lazy (mapAttrs'), so an unstaged host costs nothing and `nixos-rebuild --flake .#host-boot`
    # is a normal derivation the low-memory machine can build.
    mkBootConfig = name: host: lib.nameValuePair "${name}-boot" (mkConfig (stages.mkBootHost host));
  in
    lib.mergeAttrs
    (lib.mapAttrs' (name: host: lib.nameValuePair name (mkConfig host)) nixosHosts)
    (lib.mapAttrs' mkBootConfig (lib.filterAttrs (_: h: h.bootFeatures != []) nixosHosts));

  # ── Home Manager configuration builder ──
  buildHomeConfigurations = hostsWithPkgs: let
    hmHosts = lib.filterAttrs (_: h: !h.isNixOS) hostsWithPkgs;

    mkHomeConfigsForHost = host: let
      mkHomeConfig = user:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit (host) pkgs;
          modules = [
            (self + /modules/caches.nix)
            (self + /modules/nix-settings.nix)
            (mkUserHomeModule {inherit user host;})
            {targets.genericLinux.enable = lib.mkDefault true;}
          ];
          extraSpecialArgs = inputArgs;
        };
    in
      map (user: lib.nameValuePair "${user}@${host.name}" (mkHomeConfig user)) host.hmUsernames;
  in
    builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: mkHomeConfigsForHost) hmHosts));
in {
  inherit
    buildNixosConfigurations
    buildHomeConfigurations
    ;
}
