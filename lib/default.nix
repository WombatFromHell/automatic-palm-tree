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
  mkUnstablePkgs = system:
    import inputs.nixpkgs-unstable {
      inherit system;
      overlays = [baseOverlay];
      config.allowUnfree = true;
    };

  # ── pre-compute one package set per host ──
  # This runs once here so both config builders share one pkgs, which carries the
  # unstable set as a member rather than as a second argument to thread. Feature
  # overlays are *not* applied here: they are modules that set `nixpkgs.overlays`,
  # which nixpkgs appends to this set at eval time so they can be gated on options.
  hostsWithPkgs =
    lib.mapAttrs (
      _name: host:
        host
        // {
          pkgs = import inputs.nixpkgs {
            inherit (host) system;
            overlays = [baseOverlay (_: _: {unstable = mkUnstablePkgs host.system;})];
            config.allowUnfree = true;
          };
        }
    )
    discoveredHosts;
in {
  nixosConfigurations = buildNixosConfigurations hostsWithPkgs;
  homeConfigurations = buildHomeConfigurations hostsWithPkgs;
}
