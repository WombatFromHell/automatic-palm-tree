{pkgs, ...}: {
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
  ];

  # ── Darwin system packages (not home-manager packages) ────────────
  environment.systemPackages = with pkgs; [
    git
    kitty
    neovim
    nodejs_25
    corepack

    # fonts
    nerd-fonts.hack
    nerd-fonts.fira-mono
  ];
  programs = {
    zsh.enable = true;
  };
}
