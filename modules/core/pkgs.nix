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

  mkHostPkgs = host: let
    system = host.system or "x86_64-linux";
    unfreeStable = host.unfreeStable or [];
    unfreeUnstable = host.unfreeUnstable or [];
  in {
    inherit system unfreeStable unfreeUnstable;
    pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfreeStable;
    };
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfreeUnstable;
    };
  };
}
