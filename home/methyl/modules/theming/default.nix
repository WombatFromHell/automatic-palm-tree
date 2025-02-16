{
  lib,
  pkgs,
  config,
  ...
}: let
  upperFirst = s:
    if s == ""
    then "" # Handle empty strings
    else lib.strings.toUpper (builtins.substring 0 1 s) + builtins.substring 1 (builtins.stringLength s - 1) s;

  pointerCursorTheme = {
    name = "Bibata-Modern-Classic";
    size = 24;
    package = pkgs.bibata-cursors;
  };

  mkThemeConfig = variant: accent: {
    inherit variant accent;
    variantCapd = upperFirst variant;
    accentCapd = upperFirst accent;
  };
  themeConfig = mkThemeConfig "mocha" "teal";

  kvantumThemePkg = pkgs.catppuccin-kvantum.override {
    inherit (themeConfig) variant accent;
  };
  themeId = "catppuccin-${themeConfig.variant}-${themeConfig.accent}";
in {
  options.theming.enable = lib.mkEnableOption "Enable user customized theming";

  config = lib.mkIf config.theming.enable {
    home = {
      packages = with pkgs; [
        (catppuccin-kde.override {
          flavour = [themeConfig.variant];
          accents = [themeConfig.accent];
          winDecStyles = ["classic"];
        })
        #
        # qt5/qt6 libs currently busted
        #
        # (catppuccin-kvantum.override {
        #   inherit (themeConfig) variant accent;
        # })
        # libsForQt5.qtstyleplugin-kvantum
        # kdePackages.qtstyleplugin-kvantum
        # libsForQt5.qt5ct
        # kdePackages.qt6ct
      ];

      pointerCursor = {
        inherit (pointerCursorTheme) name size package;
        x11.enable = true;
        gtk.enable = true;
      };
    };

    # qt = {
    #   enable = true;
    #   platformTheme = "qt5ct";
    #   style = "kvantum";
    # };
    # xdg.configFile = {
    #   "Kvantum/kvantum.kvconfig".text = ''
    #     [General]
    #     theme=${themeId}
    #   '';
    #   "Kvantum/${themeId}".source = "${kvantumThemePkg}/share/Kvantum/${themeId}";
    # };

    gtk = {
      enable = true;
      theme = {
        name = "${themeId}-compact+rimless,black";
        package = pkgs.catppuccin-gtk.override {
          inherit (themeConfig) variant;
          accents = [themeConfig.accent];
          size = "compact";
          tweaks = ["rimless" "black"];
        };
      };
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.catppuccin-papirus-folders.override {
          flavor = themeConfig.variant;
          inherit (themeConfig) accent;
        };
      };
      cursorTheme = {
        inherit (pointerCursorTheme) name package size;
      };
    };
    dconf.settings = {
      "org/gnome/desktop/interface".color-scheme = "prefer-dark";
    };
  };
}
