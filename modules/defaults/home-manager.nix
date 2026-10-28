{config, ...}: {
  # Any configuration warning fails the build; Home Manager throws on failed assertions when
  # its activation package is forced, and nixpkgs' assertions module declares both options.
  imports = [../warnings-gate.nix];
  manual = {
    html.enable = false;
    json.enable = false;
    manpages.enable = false;
  };
  programs.home-manager.enable = true;
  home.stateVersion = "24.11";

  # nixGL wraps a GUI package when the hm-nixgl feature is on; without it the
  # package is used as-is, so every consumer can call this unconditionally.
  lib.nixGL.wrapMesa = pkg:
    if config.lib ? nixGL
    then config.lib.nixGL.wrappers.mesa pkg
    else pkg;
}
