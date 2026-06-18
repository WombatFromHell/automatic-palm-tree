{lib, ...}: {
  options = {
    bootstrap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable cache-dependent options during initial deployment.";
    };

    system = lib.mkOption {
      type = lib.types.str;
      description = "System architecture (e.g., x86_64-linux).";
    };

    isNixOS = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to build a NixOS configuration for this host.";
    };

    users = lib.mkOption {
      # attrsOf with a basic submodule inline keeps it flat
      type = lib.types.attrsOf (lib.types.submodule {
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
          };
        };
      });
      default = {};
      description = "Users defined for this host.";
    };

    isQemuVM = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this host is a QEMU/KVM virtual machine.";
    };

    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Features to enable for this host.";
    };

    # ── Flattened Module Lists ──────────────────────────────────────────
    # Instead of a nested submodule, we just use flat lists.
    # This eliminates the need for complex schema definitions for modules.
    nixosModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      description = "Host-local NixOS modules.";
    };

    sharedModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      description = "Host-local shared modules applied to both NixOS and HM.";
    };

    homeModules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.unspecified);
      default = {};
      description = "Per-user Home Manager modules, keyed by username.";
    };
  };
}
