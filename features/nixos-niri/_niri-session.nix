{
  pkgs,
  lib,
  config,
}: let
  desktop = import ./_desktop.nix {inherit config;};

  # Delegation entry (uwsm README): Exec must reference another session entry.
  # That is how XDG_CURRENT_DESKTOP=niri and wayland-session@niri.desktop
  # naming come from upstream niri.desktop's DesktopNames, instead of the
  # hardcoded `uwsm start -F -- /run/.../niri` entry programs.uwsm generates.
  entry = pkgs.writeText "niri-uwsm.desktop" ''
    [Desktop Entry]
    Name=Niri (UWSM)
    Comment=A scrollable-tiling Wayland compositor, session-managed by UWSM
    Exec=uwsm start -- niri.desktop
    TryExec=${pkgs.uwsm}/bin/uwsm
    Type=Application
  '';

  # uwsm sources uwsm/env-<desktop>.d/* from XDG_DATA_DIRS (see
  # /usr/libexec/uwsm/prepare-env.sh), so session-scoped env belongs here.
  # home-manager systemd.user.sessionVariables applies to EVERY user session,
  # which is how Plasma-specific env used to leak into a GNOME session.
  env = pkgs.writeText "niri-uwsm-env" (lib.concatStringsSep "\n" ([
      ''export QT_QPA_PLATFORM="wayland"''
      ''export QT_WAYLAND_DISABLE_WINDOWDECORATION="1"''
      ''export NIXOS_OZONE_WL="1"''
    ]
    ++ lib.optionals (desktop == "kde") [
      # Plasma app menus + Kirigami QML; nothing else owns these.
      ''export XDG_MENU_PREFIX="plasma-"''
      ''export QML2_IMPORT_PATH="${pkgs.kdePackages.kirigami-addons}/lib/qt-6/qml:${pkgs.kdePackages.plasma-desktop}/lib/qt-6/qml"''
    ]));
in
  pkgs.runCommand "niri-uwsm-session" {
    # One package for both DM-visible entry and uwsm env drop-in: programs.uwsm
    # already links /share/wayland-sessions and /share/uwsm into the system path.
    passthru.providedSessions = ["niri-uwsm"];
  } ''
    mkdir -p "$out/share/wayland-sessions" "$out/share/uwsm/env-niri.d"
    install -m644 ${entry} "$out/share/wayland-sessions/niri-uwsm.desktop"
    install -m644 ${env} "$out/share/uwsm/env-niri.d/20-flakeroot.conf"
  ''
