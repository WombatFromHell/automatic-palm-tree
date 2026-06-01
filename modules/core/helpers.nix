{ lib, inputs, self }: {
  # ── Unfree schema module ──────────────────────────────────────────────────
  mkUnfreeOptionsModule = {
    options.unfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
    };
  };

  # ── Extract unfree lists from module paths (dry-run eval) ────────────────
  extractUnfree = mkUnfreeOptionsModule: modulePaths:
    lib.evalModules {
      modules = modulePaths ++ [ mkUnfreeOptionsModule {_module.check = false;} ];
      specialArgs = {
        pkgs = throw "'unfree' lists must be static";
        pkgsUnstable = throw "'unfree' lists must be static";
        inherit lib; config = {}; options = {}; inputs = {}; self = {};
      };
    };

  # ── Assemble host home modules (home + shared) ───────────────────────────
  hostHmModules = host:
    lib.flatten [(host.modules.home or []) (host.modules.shared or [])];
}
