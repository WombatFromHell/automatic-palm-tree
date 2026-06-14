{lib, ...}: {
  # ── Unfree declaration schema ──────────────────────────────────────────────
  # NixOS modules and HM modules declare `unfree = [ "pkg-name" ]` using this.
  mkUnfreeOptionsModule = {
    options.unfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      description = "Unfree packages permitted from pkgs and pkgsUnstable.";
    };
  };

  # ── Dry-run extractor ──────────────────────────────────────────────────────
  # Evaluates module paths in isolation purely to extract their unfree lists.
  # Throws if any module attempts to actually evaluate pkgs.
  extractUnfree = mkUnfreeOptionsModule: modulePaths: extraSpecialArgs:
    if modulePaths == []
    then {config = {unfree = [];};}
    else
      lib.evalModules {
        modules =
          modulePaths
          ++ [
            mkUnfreeOptionsModule
            {_module.check = false;}
            # Provide inert stubs for all common args
            {
              imports = [
                {
                  _module.args.pkgs = throw "pkgs accessed during unfree extraction";
                  _module.args.pkgsUnstable = throw "pkgsUnstable accessed during unfree extraction";
                }
              ];
            }
          ];
        specialArgs =
          {
            inherit lib;
            config = {};
            options = {};
            inputs = {};
            self = {};
            hostConfig = {};
          }
          // extraSpecialArgs;
      };

  # ── Overlay declaration schema ─────────────────────────────────────────────
  # Feature modules declare `overlays = [ ... ]` using this.
  mkOverlaysOptionsModule = {
    options.featureOverlays = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified; # Use unspecified to avoid deep type checking
      default = [];
      internal = true;
      description = "Nixpkgs overlays contributed by this feature module.";
    };
  };

  extractOverlays = mkOverlaysOptionsModule: modulePaths: inputs: extraSpecialArgs:
    if modulePaths == []
    then []
    else
      (lib.evalModules {
        modules =
          modulePaths
          ++ [
            mkOverlaysOptionsModule
            {_module.check = false;}
            # CRITICAL: Completely disable config evaluation to prevent pkgs access
            {config = lib.mkForce {};}
            # Provide inert stubs for all common pkgs-dependent args
            {
              imports = [
                {
                  _module.args.pkgs = throw "pkgs accessed during overlay extraction";
                  _module.args.pkgsUnstable = throw "pkgsUnstable accessed during overlay extraction";
                }
              ];
            }
          ];
        specialArgs =
          {
            inherit lib inputs;
            config = {};
            options = {};
            self = {};
            hostConfig = {};
          }
          // extraSpecialArgs;
      }).config.featureOverlays;

  # ── Package set factory ────────────────────────────────────────────────────
  # mkPkgs inputs.nixpkgs         system unfree []               → stable
  # mkPkgs inputs.nixpkgs-unstable system unfree [nixgl.overlay] → unstable
  mkPkgs = pkgsInput: system: unfree: overlays:
    import pkgsInput {
      inherit system overlays;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };
}
