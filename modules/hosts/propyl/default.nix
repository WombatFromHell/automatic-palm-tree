{
  pkgs,
  inputs,
  ...
}: {
  # ── Host metadata ─────────────────────────────────────────────────
  hostArgs = {
    hostname = "propyl";
    system = "x86_64-darwin";
    username = "josh";
    myuid = 501;
    hostType = "darwin";
  };

  # ── Module imports ────────────────────────────────────────────────
  imports = [
    ../../darwin
    inputs.home-manager-darwin.darwinModules.home-manager
  ];

  # ── Home-manager (inline, needed for darwin system config) ────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm";
    users.josh.imports = [../../home-manager];
  };

  home.packages = with pkgs; [
    # Fonts
    nerd-fonts.hack
    nerd-fonts.fira-mono
  ];
  programs = {
    zsh.enable = true;
    fish.enable = true;
    ghostty.enable = true;
  };
}
