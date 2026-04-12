{
  # Target platform for this host (overrides default "x86_64-linux")
  system = "x86_64-darwin";

  # System-level configuration (evaluated as a module)
  module = {pkgs, ...}: {
    imports = [../../darwin];

    environment.systemPackages = with pkgs; [
      git
      gnupg
      kitty

      # node is required for lazyvim
      neovim
      nodejs_25
      corepack

      # fonts
      nerd-fonts.hack
      nerd-fonts.fira-mono
    ];

    programs.zsh.enable = true;
  };
}
