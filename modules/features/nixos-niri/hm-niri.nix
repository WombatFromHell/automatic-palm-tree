{lib, pkgs, ...}: {
  systemd.user.sessionVariables = {
    XDG_MENU_PREFIX = "plasma-";
    QT_QPA_PLATFORM = "wayland";
    QT_QPA_PLATFORMTHEME = "kde";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "0";
    NIXOS_OZONE_WL = "1";
    QML2_IMPORT_PATH = lib.concatStringsSep ":" [
      "${pkgs.kdePackages.kirigami-addons}/lib/qt-6/qml"
      "${pkgs.kdePackages.plasma-desktop}/lib/qt-6/qml"
    ];
  };
}
