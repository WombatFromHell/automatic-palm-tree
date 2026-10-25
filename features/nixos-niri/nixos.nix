{
  pkgs,
  config,
  lib,
  ...
}: let
  cfg = config.features.niri;
  # Same DE probe as _niri.nix/_niri-portals.nix: qt6ct is Plasma's Qt theme tool,
  # so it belongs only in a KDE session.
  isKde = (import ./_desktop.nix {inherit config;}) == "kde";

  # `niri` + `xwayland-satellite`: ./_overlays.nix swaps both names in the package set
  # when `features.niri.niriSpicy.enable` is set (nixpkgs appends `nixpkgs.overlays` to the
  # pinned `nixpkgs.pkgs`), so the enabled branch reads them by plain name. Off: unstable
  # niri, nixpkgs xwayland-satellite.
  niriPackages =
    if cfg.niriSpicy.enable
    then [pkgs.niri pkgs.xwayland-satellite]
    else [pkgs.unstable.niri pkgs.xwayland-satellite];
in {
  imports = [
    ./_niri.nix
    ./_niri-portals.nix
  ];

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs;
      niriPackages
      ++ lib.optionals isKde [kdePackages.qt6ct]
      ++ [
        pkgs.unstable.dsearch
        liberation_ttf
        noto-fonts
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
