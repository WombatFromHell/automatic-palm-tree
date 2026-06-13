{
  lib,
  pkgs,
  hostConfig,
  ...
}: {
  home.packages = with pkgs;
    [
      # Dev tools
      alejandra
      ansible
      ansible-lint
      bats
      gcc
      lazydocker
      lazygit
      mise
      nil
      nixd
      prettier
      python3
      python3Packages.pytest
      ruff
      shellcheck
      shfmt
      statix
      ty
      uv
    ]
    # only add nerd-fonts if we're on NixOS
    ++ (lib.optionals (hostConfig.isNixOS or false) [
      nerd-fonts.jetbrains-mono
      nerd-fonts.fira-code
      nerd-fonts.iosevka
    ]);

  programs = {
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        global = {
          log_format = "";
        };
      };
    };
  };
}
