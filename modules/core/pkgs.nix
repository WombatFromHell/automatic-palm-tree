{
  lib,
  inputs,
}: {
  # Single parameterized pkgs factory. Callers bind the input:
  #   mkPkgs inputs.nixpkgs         → stable
  #   mkPkgs inputs.nixpkgs-unstable → unstable
  mkPkgs = pkgsInput: system: unfree: overlays:
    import pkgsInput {
      inherit system overlays;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };
}
