{
  config,
  lib,
  ...
}:
# ── GNOME dark-mode preference ──
# Enforces the dark interface preference through GNOME's documented dconf key
# (org.gnome.desktop.interface color-scheme='prefer-dark'). The feature is
# host-agnostic (no nixos.nix), so mergeHome's nixos-* filter never drops it:
# it works on standalone HM hosts (methyl-bazzite) and NixOS-managed hosts
# alike.
#
# Deliberately NOT done: GTK theme / gtk-theme-setting writes. Home Manager's
# programs.gtk resets gtk-theme-setting, which would clear GNOME 47+'s atomic
# theme switch set by the control-center dark-mode toggle. GNOME follows
# color-scheme on its own; GTK apps follow gtk-theme-setting. Setting both
# from HM is the implementation tug-of-war this module avoids. No KWin or
# Plasma color-scheme writes either — pinned KDE (nixpkgs 26.11) has no
# dark-mode option and pinning the KWin DarkMode effect needs an unfree
# plugin outside nixpkgs.
let
  cfg = config.features.gnome-dark;
in {
  options.features.gnome-dark.enable = lib.mkEnableOption "GNOME dark interface preference via dconf" // {default = true;};

  config = lib.mkIf cfg.enable {
    dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
  };
}
