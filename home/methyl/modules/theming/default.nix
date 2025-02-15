{
  lib,
  pkgs,
  config,
  ...
}: let
  pointerCursorTheme = {
    name = "Bibata-Modern-Classic";
    size = 24;
    package = pkgs.bibata-cursors;
  };
in {
  options.theming.enable = lib.mkEnableOption "Enable user customized theming";

  config = lib.mkIf config.theming.enable {
    home = {
      packages = with pkgs; [
        (catppuccin-kde.override {
          flavour = ["mocha"];
          accents = ["teal"];
          winDecStyles = ["classic"];
        })
      ];

      pointerCursor = {
        inherit (pointerCursorTheme) name size package;
        x11.enable = true;
        gtk.enable = true;
      };
    };

    gtk = {
      enable = true;
      theme = {
        # name = "Breeze"
        # package = pkgs.libsForQt5.breeze-gtk;

        name = "Catppuccin-Mocha-Standard-Teal-Dark";
        package = pkgs.catppuccin-gtk.override {
          accents = ["teal"];
          size = "standard";
          variant = "mocha";
        };
      };
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.catppuccin-papirus-folders.override {
          flavor = "mocha";
          accent = "teal";
        };
      };
      cursorTheme = {
        inherit (pointerCursorTheme) name package size;
      };
    };
    xdg.configFile = {
      "gtk-4.0/assets".source = "${config.gtk.theme.package}/share/themes/${config.gtk.theme.name}/gtk-4.0/assets";
      "gtk-4.0/gtk.css".source = "${config.gtk.theme.package}/share/themes/${config.gtk.theme.name}/gtk-4.0/gtk.css";
      "gtk-4.0/gtk-dark.css".source = "${config.gtk.theme.package}/share/themes/${config.gtk.theme.name}/gtk-4.0/gtk-dark.css";
    };
    dconf.settings = {
      "org/gnome/desktop/interface".color-scheme = "prefer-dark";
    };

    # plasma-manager config
    # programs.plasma = {
    #   enable = false;
    #   shortcuts = {
    #     # make alacritty the defacto terminal via Ctrl+Alt+T
    #     "services/Alacritty.desktop"."New" = "Ctrl+Alt+T";
    #     "services/org.kde.konsole.desktop"."_launch" = [];
    #   };
    #   configFile = {
    #     "kcminputrc"."Keyboard"."RepeatDelay" = 333;
    #     "kcminputrc"."Keyboard"."RepeatRate" = 33;
    #     "kcminputrc"."Mouse"."cursorTheme" = "default";
    #     "kdeglobals"."Icons"."Theme" = "breeze-dark";
    #     "kdeglobals"."KDE"."widgetStyle" = "Breeze";
    #     "ksplashrc"."KSplash"."Engine" = "none";
    #     "ksplashrc"."KSplash"."Theme" = "None";
    #   };
    # };
  };
}
