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
      description = "Unfree packages permitted from pkgs and pkgsUnstable.";
    };
  };
}
