# 'pi-web': the Web UI for Pi sessions, built from the pinned commit in ./metadata.json (see
# ./_package.nix).
#
# Opt-in through the host feature list (hosts/<host>/default.nix or a profile → "hm-piweb"), like
# every other feature — the feature list is the gate, no extra enable flag.
#
# The three binaries go on PATH through home.packages: pi-web (TUI), pi-web-server (the web server)
# and pi-web-sessiond (the session supervisor). Nothing here runs `pi-web install`: that writes
# systemd units into ~/.config/systemd from a launcher outside the store, and `pi-web update` runs
# `npm install -g`. The store tree is the installation and ./update.sh moves it.
{pkgs, ...}: let
  # Bound, not written inside the list literal: `[f x {}]` is a three-element list in Nix.
  pi-web = pkgs.callPackage ./_package.nix {};
in {
  home.packages = [pi-web];
}
