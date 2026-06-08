{pkgs, ...}: {
  home.packages = with pkgs; [
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
    nixfmt
    prettier
    python3
    python3Packages.pytest
    ruff
    shellcheck
    shfmt
    statix
    ty
    uv
  ];

  programs = {
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        global = {log_format = "";};
      };
    };
  };
}
