# Gated overlay: swaps `niri` and `xwayland-satellite` in the host's package set only when
# ./_spicy.nix says yes (option on *and* the wombatfromhell cache substituted), so the
# feature module reads them by plain name either way.
{
  config,
  lib,
  inputs,
  ...
}: {
  config.nixpkgs.overlays = lib.mkIf (import ./_spicy.nix {inherit config lib;}) [
    inputs.niri-spicy.overlays.default
  ];
}
