{lib, ...}: {
  options = {
    bootstrap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable cache-dependent options during initial deployment.";
    };

    system = lib.mkOption {
      type = lib.types.str;
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            isAdmin = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            hmEnabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable the home-manager module for this user.";
            };
          };
        }
      );
      default = {};
    };

    isNixOS = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };

    unfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      description = "Unfree packages permitted from pkgs and pkgsUnstable.";
    };

    modules = lib.mkOption {
      type = lib.types.submodule {
        options = {
          nixos = lib.mkOption {
            type = lib.types.listOf lib.types.deferredModule;
            default = [];
            description = "Host-local NixOS modules.";
          };
          shared = lib.mkOption {
            type = lib.types.listOf lib.types.deferredModule;
            default = [];
            description = "Host-local shared modules.";
          };
          perUser = lib.mkOption {
            type = lib.types.attrsOf (lib.types.listOf lib.types.deferredModule);
            default = {};
            description = ''
              Per-user Home Manager modules for this host.
              Keyed by username. Replaces the modules.home.<user> pattern
              used in single-file host declarations.
            '';
          };
        };
      };
      default = {};
      description = "Host-local NixOS and Home Manager modules.";
    };
  };
}
