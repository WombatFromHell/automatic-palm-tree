{
  lib,
  config,
  ...
}: let
  cfg = config.features.theming;
in {
  imports = [./_theme.nix];

  config = lib.mkIf cfg.enable {
    home = {
      # Cursor Theming
      pointerCursor = {
        name = cfg.cursorTheme.name;
        package = cfg.cursorTheme.package;
        gtk.enable = true;
        x11.enable = true;
        size = cfg.cursorTheme.size;
      };
    };
    systemd.user.sessionVariables = {
      GTK_THEME = cfg.gtkTheme.name;
      QT_QPA_PLATFORMTHEME = cfg.qt.platformTheme;
      XCURSOR_THEME = cfg.cursorTheme.name;
      XCURSOR_SIZE = toString cfg.cursorTheme.size;
    };
  };
}
