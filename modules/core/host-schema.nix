# modules/core/host-schema.nix
{lib, ...}: {
  options = {
    system = lib.mkOption {
      type = lib.types.str;
    };

    # Legacy single-user option — still accepted by flat .nix host files.
    # Builders should prefer `usernames` (derived in discovery.nix).
    username = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    # New multi-user option: keys are usernames, values carry per-user metadata.
    # `enabled` defaults to true; set false to exclude a user entirely.
    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
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
      description = "Unfree packages permitted from pkgs (stable channel).";
    };

    unfreeUnstable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Unfree packages permitted from pkgsUnstable (unstable channel).";
    };
  };
}
