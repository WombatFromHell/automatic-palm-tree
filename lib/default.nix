# Composition root: pulls in every loader concern below, resolves per-host package
# sets once, and returns the flake outputs. flake.nix imports this file directly.
{
  lib,
  self,
  inputs,
  ...
}: let
  # ── host option schema (lib/host-options.nix) ──
  inherit (import ./host-options.nix {inherit lib;}) hostOptions flakeHostOptions;

  # ── feature machinery (lib/features.nix) ──
  features = import ./features.nix {inherit lib self;};
  inherit (features) discoveredFeatures;

  # ── pin metadata contract (lib/pin-meta.nix) ──
  pinMeta = import ./pin-meta.nix {inherit lib;};

  # ── config builders (lib/builders.nix) ──
  builders = import ./builders.nix {inherit lib self inputs features flakeHostOptions;};
  inherit (builders) buildNixosConfigurations buildHomeConfigurations;

  # ── host helpers (lib/host-lib.nix) ──
  hostLib = import ./host-lib.nix {inherit lib;};

  # ── host pipeline (lib/hosts.nix) ──
  hosts = import ./hosts.nix {
    inherit lib self hostLib;
    inherit hostOptions;
  };
  inherit (hosts) discoveredHosts;

  # ── package-set members, always on ──
  # Feature modules read flake packages through the package set
  # (`flakePackages.<name>.<system>.default`) so a package read is a value, like every
  # other package read. `inputs` still carries module *paths*, which the module system
  # cannot see (`imports = [inputs.agenix.homeManagerModules.default]` runs before eval).
  # `self` is excluded: a `packages` output on the flake later would point back at
  # the host configs and cycle here.
  flakePackages =
    lib.mapAttrs (_: input: input.packages)
    (lib.filterAttrs (_: input: input ? packages) (builtins.removeAttrs inputs ["self"]));

  # Both members land in every package set this file builds, so a derivation reads
  # them through callPackage like a build dependency.
  baseOverlay = _final: _prev: {inherit pinMeta flakePackages;};

  # The unstable set gets baseOverlay only: it is read as `pkgs.unstable`, a member of
  # the set above it, so it must never ask for itself.
  unstableFor = lib.genAttrs systems (system:
    import inputs.nixpkgs-unstable {
      inherit system;
      overlays = [baseOverlay];
      config.allowUnfree = true;
    });

  # ── one package set per system, shared by the hosts that target it ──
  # Every host here is x86_64-linux, so per-host instantiation was four copies of the same
  # tree (and four of the unstable one). Feature overlays are *not* applied here: they are
  # modules that set `nixpkgs.overlays`, which nixpkgs appends to this set at eval time so
  # they can be gated on options.
  systems = lib.unique (map (h: h.system) (lib.attrValues discoveredHosts));
  pkgsFor = lib.genAttrs systems (system: import inputs.nixpkgs {
    inherit system;
    overlays = [baseOverlay (_: _: {unstable = unstableFor.${system};})];
    config.allowUnfree = true;
  });
  hostsWithPkgs =
    lib.mapAttrs (_name: host: host // {pkgs = pkgsFor.${host.system};}) discoveredHosts;
in {
  # Exported so tooling and tests read the loader's own package set instead of
  # reaching through a built configuration (`homeConfigurations.<key>.pkgs`).
  inherit hostsWithPkgs;
  nixosConfigurations = buildNixosConfigurations hostsWithPkgs;
  homeConfigurations = buildHomeConfigurations hostsWithPkgs;
}
