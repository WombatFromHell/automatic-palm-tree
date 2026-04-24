{
  pkgs,
  username,
  ...
}: {
  imports = [../../darwin];

  users.users.${username} = {
    shell = pkgs.fish;
  };

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
}
