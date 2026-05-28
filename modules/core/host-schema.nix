# modules/core/host-schema.nix
{
  lib,
  config,
  ...
}: {
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

    # 'modules' is intentionally REMOVED from here!

    unfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };

    unfreeStable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
    };

    unfreeUnstable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
    };
  };

  config = {
    unfreeStable = lib.mkDefault config.unfree;
    unfreeUnstable = lib.mkDefault config.unfree;
  };
}
