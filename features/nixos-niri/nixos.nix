{
  pkgs,
  pkgsUnstable,
  ...
}: {
  imports = [
    ./_niri.nix
    ./_niri-portals.nix
  ];

  environment.systemPackages = with pkgs; [
    pkgsUnstable.niri
    pkgsUnstable.dsearch
    kanshi
    kdePackages.qt6ct
    liberation_ttf
    noto-fonts
    xwayland-satellite
  ];

  security.polkit.enable = true;

  programs.uwsm.enable = true;
}
