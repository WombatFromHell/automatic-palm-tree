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

  # GPU drivers come from nixGL only where the host has none. Home Manager's own lib.nixGL.wrap
  # picks the wrapper from targets.genericLinux.nixGL.defaultWrapper (features/hm-nixgl sets it
  # per host) and is a no-op when packages is null, but it only exists when the genericLinux
  # target is on — so every feature calls this instead, and a NixOS host gets its package as-is.
  lib.nixGL.wrapGpu = pkg:
    if config.lib ? nixGL
    then config.lib.nixGL.wrap pkg
    else pkg;
}
