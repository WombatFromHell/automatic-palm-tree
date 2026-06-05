{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.theming;
  breezePkgs = pkgs.kdePackages;
in {
  options.features.theming = {
    enable = lib.mkEnableOption "Enable consistent default theming across Qt, GTK, and Wayland";

    gtkTheme = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "Breeze-Dark";
        description = "Name of the GTK theme.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = breezePkgs.breeze-gtk;
        description = "Package providing the GTK theme.";
      };
    };

    iconTheme = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "breeze-dark";
        description = "Name of the icon theme.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = breezePkgs.breeze-icons;
        description = "Package providing the icon theme.";
      };
    };

    cursorTheme = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "breeze_cursors";
        description = "Name of the cursor theme.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = breezePkgs.breeze;
        description = "Package providing the cursor theme.";
      };
      size = lib.mkOption {
        type = lib.types.int;
        default = 32;
        description = "Size of the cursor (e.g., 24, 32, 48 for HiDPI).";
      };
    };

    qt = {
      platformTheme = lib.mkOption {
        type = lib.types.str;
        default = "kde";
        description = "Qt platform theme.";
      };
      style = lib.mkOption {
        type = lib.types.str;
        default = "breeze-dark";
        description = "Qt widget style.";
      };
      colorScheme = lib.mkOption {
        type = lib.types.str;
        default = "BreezeDark";
        description = "KDE/Qt color scheme name.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Qt Theming
    qt = {
      enable = true;
      platformTheme.name = cfg.qt.platformTheme;
      style.name = cfg.qt.style;
    };

    # GTK 2 & 3 Theming
    gtk = {
      enable = true;
      theme = {
        name = cfg.gtkTheme.name;
        package = cfg.gtkTheme.package;
      };
      iconTheme = {
        name = cfg.iconTheme.name;
        package = cfg.iconTheme.package;
      };

      # GTK4 Theming: Explicitly adopt 26.05+ behavior
      gtk4.theme = lib.mkDefault null;
    };

    home = {
      # Cursor Theming
      pointerCursor = {
        name = cfg.cursorTheme.name;
        package = cfg.cursorTheme.package;
        gtk.enable = true;
        x11.enable = true;
        size = cfg.cursorTheme.size;
      };
      # Environment Variables
      sessionVariables = {
        GTK_THEME = cfg.gtkTheme.name;
        QT_QPA_PLATFORMTHEME = cfg.qt.platformTheme;
        XCURSOR_THEME = cfg.cursorTheme.name;
        XCURSOR_SIZE = toString cfg.cursorTheme.size;
      };
    };
  };
}
