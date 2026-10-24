{
  lib,
  config,
  ...
}: let
  cfg = config.features.gnome;
in {
  options.features.gnome = {
    enable = lib.mkEnableOption "GNOME desktop environment (GDM login screen)" // {default = true;};
  };

  # gnome.nix does not enable GDM itself (its gdm line is a nixos-generate-config string).
  # dconf, portals and the gnome session entry come from desktopManager.gnome.
  config = lib.mkIf cfg.enable {
    services.displayManager.gdm.enable = true;
    services.desktopManager.gnome.enable = true;
    gnome.gnome-keyring.enable = true;
  };
}
