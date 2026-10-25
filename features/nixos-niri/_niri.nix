{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.niri;
  desktop = import ./_desktop.nix {inherit config;};
  isKde = desktop == "kde";
  niri-session = import ./_niri-session.nix {inherit pkgs lib config;};
in {
  options.features.niri = {
    enable = lib.mkEnableOption "Niri compositor configuration" // {default = true;};
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /etc/niri 0755 root root - -"
    ];

    # Upstream session config: symlink the kdl straight from the repo, no
    # writeText(readFile) copy.
    environment.etc."niri/config.kdl".source = ./config.kdl;

    # KDE menu workaround: only meaningful when Plasma is the installed desktop.
    environment.etc."xdg/menus/applications.menu" = lib.mkIf isKde {
      source = "${pkgs.kdePackages.plasma-workspace}/etc/xdg/menus/plasma-applications.menu";
    };
    system.activationScripts.kbuildsycoca6 = lib.mkIf isKde {
      # post activation rebuild via kbuildsycoca6 to fix menus
      text = ''
        echo "Rebuilding KDE service cache..."
        export XDG_MENU_PREFIX=plasma-
        export XDG_DATA_DIRS="${pkgs.kdePackages.plasma-desktop}/share:${pkgs.kdePackages.kservice}/share:/run/current-system/sw/share"
        ${pkgs.kdePackages.kservice}/bin/kbuildsycoca6 --noincremental 2>/dev/null || true
      '';
      deps = ["specialfs"];
    };

    # KDE helper agents, scoped to the niri uwsm session target: they never
    # start in a Plasma session (Plasma starts its own) or a GNOME session.
    systemd.user.services = lib.mkIf isKde {
      polkit-kde-agent-uwsm = {
        description = "KDE polkit authentication agent (niri session)";
        unitConfig = {
          PartOf = ["wayland-session@niri.desktop.target"];
          After = ["wayland-session@niri.desktop.target"];
        };
        wantedBy = ["wayland-session@niri.desktop.target"];
        serviceConfig = {
          ExecStart = "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1";
          Restart = "on-failure";
        };
      };
      kwallet-pam-init-uwsm = {
        description = "KWallet PAM initialization (niri session)";
        unitConfig = {
          PartOf = ["wayland-session@niri.desktop.target"];
          After = ["wayland-session@niri.desktop.target"];
        };
        wantedBy = ["wayland-session@niri.desktop.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.kdePackages.kwallet-pam}/libexec/pam_kwallet_init";
        };
      };
    };

    # Session entry delegates to upstream niri.desktop, so niri runs inside
    # wayland-wm@niri.desktop.service and gets XDG_CURRENT_DESKTOP=niri.
    services.displayManager.sessionPackages = [niri-session];
  };
}
