{
  lib,
  self,
  inputs,
  ...
}: let
  # ── host option schema (lib/host-options.nix) ──
  inherit (import ./host-options.nix {inherit lib;}) hostOptions;

  # ── feature machinery (lib/features.nix) ──
  features = import ./features.nix {inherit lib self inputs;};
  inherit (features) discoveredFeatures featureOptionsModule resolveFeaturePaths resolveHostOverlays;

  # ── config builders (lib/builders.nix) ──
  builders = import ./builders.nix {inherit lib self inputs features;};
  inherit (builders) buildNixosConfigurations buildHomeConfigurations checkAdminWarning;

  # ── host pipeline (lib/hosts.nix) ──
  hosts = import ./hosts.nix {
    inherit lib self;
    inherit hostOptions checkAdminWarning;
  };
  inherit (hosts) discoveredHosts;
in {
  inherit hostOptions discoveredFeatures featureOptionsModule resolveHostOverlays buildNixosConfigurations buildHomeConfigurations checkAdminWarning discoveredHosts;
}
