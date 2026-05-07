{pkgs, ...}: {
  home.packages = with pkgs; [
    # Dev tools
    alejandra
    ansible
    ansible-lint
    bats
    gcc
    mise
    nil
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
}
