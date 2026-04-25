{
  pkgsStable,
  pkgsUnstable,
  username,
  ...
}: {
  imports = [../../darwin];

  users.users.${username} = {
    shell = pkgsStable.fish;
  };

  environment.systemPackages = with pkgsStable; [
    git
    gnupg
    kitty

    # node is required for lazyvim
    neovim
    nodejs_24
    corepack

    # fonts
    nerd-fonts.hack
    nerd-fonts.fira-mono
  ];

  programs.zsh.enable = true;
}
