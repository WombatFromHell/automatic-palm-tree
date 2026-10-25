{
  pkgs,
  config,
  lib,
  ...
}: {
  imports = [
    ./_niri.nix
    ./_niri-portals.nix
  ];

  config = lib.mkIf config.features.niri.enable {
    environment.systemPackages = with pkgs; [
      pkgs.unstable.niri
      pkgs.unstable.dsearch
      kdePackages.qt6ct
      liberation_ttf
      noto-fonts
      xwayland-satellite
      # Upstream tools, replacing the vendored ./bin scripts: beryl-utils
      # exposes `spawn-browser` / `chromium-flags` (no .sh suffix), beryl-gamemode
      # exposes `gamemode`.
      pkgs.flakePackages.beryl-utils.${pkgs.system}.default
      pkgs.flakePackages.beryl-gamemode.${pkgs.system}.gamemode
      # Colour picker: native packages, no wrapper script (config.kdl uses
      # `spawn-sh "hyprpicker | wl-copy"`).
      hyprpicker
      wl-clipboard
    ];

    security.polkit.enable = true;

    programs.uwsm.enable = true;
  };
}
