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
        name = "Breeze-Dark";
        package = pkgs.libsForQt5.breeze-gtk;
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
      gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
      gtk4.extraConfig.gtk-application-prefer-dark-theme = true;
    };
  };
}
