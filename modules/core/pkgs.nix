{
  lib,
  inputs,
}: {
  mkPkgs = system: unfree:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };

  mkPkgsUnstable = system: unfree:
    import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };
}
