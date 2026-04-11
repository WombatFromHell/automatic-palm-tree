{pkgs, ...}: {
  home.packages = with pkgs; [
    # Dev tools
    alejandra
    ansible
    ansible-lint
    bats
    cachix
    gcc
    mise
    nil
    nixfmt
    prettier
    python314
    python314Packages.pytest
    ruff
    shellcheck
    shfmt
    statix
    ty
    uv
  ];
}
