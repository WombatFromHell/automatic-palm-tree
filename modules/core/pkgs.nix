{
  lib,
  inputs,
}: {
  # Single parameterized pkgs factory. Callers bind the input:
  #   mkPkgs inputs.nixpkgs         → stable
  #   mkPkgs inputs.nixpkgs-unstable → unstable
  mkPkgs = pkgsInput: system: unfree:
    import pkgsInput {
      inherit system;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };
}
