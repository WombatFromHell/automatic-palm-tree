# modules/core/host-schema.nix
{lib, ...}: {
  options = {
    system = lib.mkOption {
      type = lib.types.str;
    };

    username = lib.mkOption {
      type = lib.types.str;
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
