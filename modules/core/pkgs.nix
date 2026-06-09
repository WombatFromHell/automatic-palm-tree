{lib, ...}: {
  # ── Unfree declaration schema ──────────────────────────────────────────────
  # NixOS modules and HM modules declare `unfree = [ "pkg-name" ]` using this.
  mkUnfreeOptionsModule = {
    options.unfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
    };
  };

  # ── Dry-run extractor ──────────────────────────────────────────────────────
  # Evaluates module paths in isolation purely to extract their unfree lists.
  # Throws if any module attempts to actually evaluate pkgs.
  extractUnfree = mkUnfreeOptionsModule: modulePaths:
    lib.evalModules {
      modules =
        modulePaths
        ++ [
          mkUnfreeOptionsModule
          {_module.check = false;}
        ];
      specialArgs = {
        pkgs = throw "'unfree' lists must be static";
        pkgsUnstable = throw "'unfree' lists must be static";
        inherit lib;
        config = {};
        options = {};
        inputs = {};
        self = {};
      };
    };

  # ── Package set factory ────────────────────────────────────────────────────
  # mkPkgs inputs.nixpkgs         system unfree []               → stable
  # mkPkgs inputs.nixpkgs-unstable system unfree [nixgl.overlay] → unstable
  mkPkgs = pkgsInput: system: unfree: overlays:
    import pkgsInput {
      inherit system overlays;
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };
}
