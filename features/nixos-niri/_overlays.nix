# Gated overlay: `features.niri.niriSpicy.enable` swaps `niri` and `xwayland-satellite`
# in the host's package set, so the feature module reads them by plain name.
{
  config,
  lib,
  inputs,
  ...
}: {
  config.nixpkgs.overlays = lib.mkIf config.features.niri.niriSpicy.enable [
    inputs.niri-spicy.overlays.default
  ];
}
