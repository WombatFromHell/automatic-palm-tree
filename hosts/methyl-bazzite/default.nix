{
  system = "x86_64-linux";

  # Unfree package declarations — per-pkgs-input isolation.
  # If a package with a non-free license is added to systemPackages/home.packages,
  # it MUST be listed below or the build will fail with a license error.
  # To look up the exact package name: nix eval --raw nixpkgs#<pkg>.pname
  unfreeStable = [];
  unfreeUnstable = [];
}
