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
    ];

    security.polkit.enable = true;

    programs.uwsm.enable = true;
  };
}
