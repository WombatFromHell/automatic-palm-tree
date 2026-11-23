# 'pi-bolt': the pinned Pi-Bolt release binary (see ./_package.nix).
#
# Opt-in through the host feature list (hosts/<host>/default.nix or a profile → "hm-pibolt"), like
# every other feature — the feature list is the gate, no extra enable flag.
#
# Upstream names the binaries `pi` and `pi-start`, so they go on PATH as-is through home.packages.
# Nothing here installs into ~/.pi: the store tree is the installation, and ./update.sh moves it.
{pkgs, ...}: let
  # Bound, not written inside the list literal: `[f x {}]` is a three-element list in Nix.
  pi-bolt = pkgs.callPackage ./_package.nix {};
in {
  home.packages = [pi-bolt];
}
