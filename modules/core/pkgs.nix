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

  mkHostPkgs = host:
  # `system` is required — no default is provided intentionally.
  # A silent wrong-arch build is worse than a clear failure.
    if !(host ? system)
    then
      lib.warn
      "Host '${host.username}' does not declare 'system'. Evaluation cannot continue. Add e.g. system = \"x86_64-linux\"; to the host file."
      (throw "Host '${host.username}' does not declare 'system'.")
    else let
      system = host.system;
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
