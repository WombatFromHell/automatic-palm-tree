# Spicy niri is only worth pulling when the wombatfromhell cache is in this host's
# substituters: without it the fork builds locally (`fallback = true` in
# modules/defaults/nixos.nix). `flakeCache.enable` is the gate, not a bootstrap flag
# (modules/caches.nix writes the url/key into /etc/nix/nix.conf from it).
# Both ./_overlays.nix and ./nixos.nix ask this, so the overlay and the package list
# can never disagree.
{
  config,
  lib,
  ...
}:
config.features.niri.niriSpicy.enable && lib.elem "wombatfromhell" config.flakeCache.enable
