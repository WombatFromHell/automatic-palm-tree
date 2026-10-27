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

  # `niri` + `xwayland-satellite`: ./_overlays.nix swaps both names in the package set when
  # ./_spicy.nix says yes (option on *and* the wombatfromhell cache in this host's
  # substituters), so the spicy branch reads them by plain name. Otherwise: unstable niri,
  # nixpkgs xwayland-satellite.
  spicy = import ./_spicy.nix {inherit config lib;};
  niriPackages =
    if spicy
    then [pkgs.niri pkgs.xwayland-satellite]
    else [pkgs.unstable.niri pkgs.xwayland-satellite];
in {
  imports = [
    ./_niri.nix
    ./_niri-portals.nix
  ];

  config = lib.mkIf cfg.enable {
    # Names the cache so modules/caches.nix warns when spicy is asked for but this host
    # does not substitute from it.
    flakeCache.required.wombatfromhell = cfg.niriSpicy.enable;

    environment.systemPackages = with pkgs;
      niriPackages
      ++ lib.optionals isKde [kdePackages.qt6ct]
      ++ [
        pkgs.unstable.dux-search
        liberation_ttf
        noto-fonts
        # Upstream tools, replacing the vendored ./bin scripts: beryl-utils
        # exposes `spawn-browser` / `chromium-flags` (no .sh suffix), beryl-gamemode
        # exposes `gamemode`.
        pkgs.flakePackages.beryl-utils.${pkgs.stdenv.hostPlatform.system}.default
        pkgs.flakePackages.beryl-gamemode.${pkgs.stdenv.hostPlatform.system}.gamemode
        # Colour picker: native packages, no wrapper script (config.kdl uses
        # `spawn-sh "hyprpicker | wl-copy"`).
        hyprpicker
        wl-clipboard
      ];

    security.polkit.enable = true;

    programs.uwsm.enable = true;
  };
}
