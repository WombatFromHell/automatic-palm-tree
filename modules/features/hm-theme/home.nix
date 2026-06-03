{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.theming;
in {
  options.features.theming = {
    enable = lib.mkEnableOption "Enforce 'breeze-dark' theming";
  };

  config = lib.mkIf cfg.enable {
    # Qt via HM's native qt module
    qt = {
      enable = true;
      platformTheme.name = "kde";
      style.name = "breeze";
    };

    # Force Breeze Dark color scheme for the Breeze style engine
    xdg.configFile."kdeglobals".text = lib.generators.toINI {} {
      General.ColorScheme = "BreezeDark";
      KDE.LookAndFeelPackage = "org.kde.breezedark.desktop";
    };

    # GTK side
    gtk = {
      enable = true;
      theme = {
        name = "Breeze-Dark";
        package = pkgs.kdePackages.breeze-gtk;
      };
      iconTheme = {
        name = "breeze-dark";
        package = pkgs.kdePackages.breeze-icons;
      };
      cursorTheme = {
        name = "breeze_cursors";
        package = pkgs.kdePackages.breeze;
      };
    };
  };
}
