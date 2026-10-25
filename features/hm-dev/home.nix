{
  lib,
  pkgs,
  config,
  ...
}: {
  home.packages = with pkgs;
    [
      # Dev tools
      alejandra
      ansible
      ansible-lint
      aria2
      bats
      gh
      oras
      rustup
      # gcc
      pkgs.unstable.lazygit
      pkgs.unstable.lazydocker
      nil
      nixd
      npins
      python314
      ruff
      shellcheck
      shfmt
      statix
      ty
      uv
    ]
    # only add nerd-fonts if we're on NixOS
    ++ (lib.optionals config.flakeHost.isNixOS [
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
