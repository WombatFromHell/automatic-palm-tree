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
  inherit (features) resolveFeaturePaths kernelFeatures;

  # Options every feature module may read, applied to both namespaces below.
  featureOptionsModule = import (self + /modules/feature-options.nix);

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

  # ── helper: special args for host modules ──
  # `inputs` is pass-through: 6 feature modules read it, 3 of them to build an import path.
  # `fsLib` is ours, injected instead of imported so the hand-edited
  # hardware-configuration.nix still resolves it after nixos-generate-config regenerates
  # the file. Reached from nixosSystem, HM integration, and standalone HM configs below.
  inputArgs = {
    inherit inputs;
    fsLib = import (self + /lib/filesystems.nix) {
      inherit lib;
      inherit (inputs) nixpkgs;
    };
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

  # A host's own nixosModules file can pin the kernel as well as a kernel feature. The
  # module system only reports that as "boot.kernelPackages is defined multiple times"
  # with two store paths and no host name, so it is rejected here, while the host record
  # is still in hand: the message names the host and both writers. modules/defaults/nixos.nix
  # writes boot.kernelPackages too, at mkOverride 1100 (a fallback below mkDefault), so only
  # the host's own modules are scanned.
  # shortcut: reads each module's own config, not nested `imports`; upgrade if a host
  # module starts pinning the kernel from a file it imports.
  kernelPackagesWriter = m: let
    # Host modules arrive as paths, functions or attrsets, and a function module
    # returns either `{config = …}` or the config attrset itself. Called with the
    # same args nixosSystem hands a module: `lib` plus this builder's specialArgs.
    mod =
      if builtins.isPath m
      then import m
      else m;
    v =
      if builtins.isFunction mod
      then
        mod {
          inherit lib;
          inherit (inputArgs) inputs fsLib;
        }
      else mod;
    cfg = v.config or v;
  in
    (cfg.boot or {}) ? kernelPackages;

  assertOneKernelWriter = host: let
    fromFeatures = lib.filter (f: lib.elem f kernelFeatures) host.features;
    fromModules = lib.filter kernelPackagesWriter host.nixosModules;
  in
    if fromFeatures != [] && fromModules != []
    then
      throw
      "Host '${host.name}' pins boot.kernelPackages twice: feature '${lib.head fromFeatures}' (${toString features.discoveredFeatures.${lib.head fromFeatures}.nixos}) and host module ${toString (lib.head fromModules)}. Keep one."
    else {};

  # ── NixOS configuration builder ──
  buildNixosConfigurations = hostsWithPkgs: let
    nixosHosts = lib.filterAttrs (_: h: h.isNixOS) hostsWithPkgs;

    mkConfig = host:
      lib.nixosSystem {
        modules = lib.flatten [
          # Substitution first: caches.nix owns every url/key the feature modules below gate on.
          (self + /modules/caches.nix)
          # Feature modules for the NixOS platform, plus the `_overlays.nix` modules:
          # they set `nixpkgs.overlays`, which nixpkgs appends to the pinned set
          # (`nixpkgs.pkgs` above), so an overlay can be gated on a feature option.
          # Home Manager is deliberately left out: `useGlobalPkgs` shares this pkgs
          # (so gated overlays reach HM users anyway) and forbids `nixpkgs.overlays`
          # there. ponytail: a standalone (non-NixOS) host gets eager host.pkgs only —
          # gate an overlay there by setting `nixpkgs.pkgs` per config.
          {
            imports =
              resolveFeaturePaths host.features "nixos"
              ++ resolveFeaturePaths host.features "overlays"
              ++ [featureOptionsModule];
          }
          # Host facts (config.flakeHost)
          (mkHostFactsModule host)
          # Nix daemon settings
          (self + /modules/nix-settings.nix)
          # Common NixOS defaults + user defaults (merged)
          (self + /modules/defaults/nixos.nix)
          # Kernel writer check, then the host's own modules (flatten forces the check).
          # Parenthesised: without them the next line would be read as a second argument.
          (assertOneKernelWriter host)
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
  in
    lib.mapAttrs (_: mkConfig) nixosHosts;

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
