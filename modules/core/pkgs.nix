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

  mkHostPkgs = host: extraUnfree: extraUnfreeUnstable: let
    allUnfree = (host.unfree or []) ++ extraUnfree;
    allUnfreeUnstable = (host.unfreeUnstable or []) ++ extraUnfreeUnstable;
  in
    if !(host ? system)
    then
      lib.warn
      "Host '${host.username}' does not declare 'system'. Evaluation cannot continue."
      (throw "Host '${host.username}' does not declare 'system'.")
    else {
      inherit (host) system;
      pkgs = import inputs.nixpkgs {
        inherit (host) system;
        config.allowUnfreePredicate = pkg:
          builtins.elem (lib.getName pkg) allUnfree;
      };
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (host) system;
        config.allowUnfreePredicate = pkg:
          builtins.elem (lib.getName pkg) allUnfreeUnstable;
      };
    };
}
