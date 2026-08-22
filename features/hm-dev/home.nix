{
  lib,
  pkgs,
  pkgsUnstable,
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
      # gcc
      pkgsUnstable.lazygit
      pkgsUnstable.lazydocker
      nil
      nixd
      python314
      ruff
      shellcheck
      shfmt
      statix
      ty
      uv
      #
      lixPackageSets.latest.nix-fast-build
      lixPackageSets.latest.nix-eval-jobs
    ]
    # only add nerd-fonts if we're on NixOS
    ++ (lib.optionals (builtins.hasAttr "isNixOS" hostConfig && hostConfig.isNixOS) [
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
