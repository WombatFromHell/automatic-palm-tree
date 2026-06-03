_: {
  systemd.user.sessionVariables = {
    XDG_MENU_PREFIX = "plasma-";
    QT_QPA_PLATFORM = "wayland";
    QT_QPA_PLATFORMTHEME = "kde";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "0";
  };
}
