{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.niri;

  niri-tools = pkgs.stdenvNoCC.mkDerivation {
    pname = "niri-tools";
    version = "0.1.0";
    src = ./bin;
    installPhase = ''
      mkdir -p $out/bin
      cp spawn-browser.sh $out/bin/spawn-browser.sh
      cp hyprpicker.sh $out/bin/hyprpicker.sh
      chmod +x $out/bin/spawn-browser.sh $out/bin/hyprpicker.sh
    '';
  };
in {
  options.features.niri = {
    enable = lib.mkEnableOption "Niri compositor configuration";
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /etc/niri 0755 root root - -"
    ];

    environment = {
      systemPackages = [niri-tools];
      etc."niri/config.kdl".source =
        pkgs.writeText "config.kdl" (builtins.readFile ./config.kdl);
      etc."niri/services.kdl".text = ''
        // Auto-generated: startup services with correct Nix paths.
        spawn-at-startup "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1"
        spawn-at-startup "${pkgs.kdePackages.kwallet-pam}/libexec/pam_kwallet_init"
      '';
    };

    # use a workaround to fix brokenness in KDE menus
    environment.etc."xdg/menus/applications.menu".source = "${pkgs.kdePackages.plasma-workspace}/etc/xdg/menus/plasma-applications.menu";
    system.activationScripts.kbuildsycoca6 = {
      # post activation rebuild via kbuildsycoca6 to fix menus
      text = ''
        echo "Rebuilding KDE service cache..."
        export XDG_MENU_PREFIX=plasma-
        export XDG_DATA_DIRS="${pkgs.kdePackages.plasma-desktop}/share:${pkgs.kdePackages.kservice}/share:/run/current-system/sw/share"
        ${pkgs.kdePackages.kservice}/bin/kbuildsycoca6 --noincremental 2>/dev/null || true
      '';
      deps = ["specialfs"];
    };

    programs.uwsm.waylandCompositors.niri = {
      prettyName = "niri-uwsm";
      comment = "Niri (UWSM)";
      binPath = "/run/current-system/sw/bin/niri";
      extraArgs = ["--session"];
    };
  };
}
