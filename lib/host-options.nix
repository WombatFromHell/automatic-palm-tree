{lib, ...}:
# ── host option schema ──
# Every host file is validated against this. `features` is the single source
# of truth for what a host enables; the loader derives everything else.
#
# The schema is split by ownership, so the groups replace the subtract-list that
# used to have to stay in step with it:
#   hostFacts        - what a host file declares about the machine
#   authoringOptions - what a host file wires in (modules and features)
#   derivedOptions   - owned by discovery / the builders, a host file cannot set
# hostOptions is what a host file is validated against; flakeHostOptions is what
# config.flakeHost is typed with.
let
  hostFacts = {
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
  };

  authoringOptions = {
    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Features to enable for this host.";
    };
    bootFeatures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Subset of `features` for the first (light) bootstrap stage — the config a
        low-memory machine builds before it can build the full one. Empty means the
        host is not staged: `bootstrap.sh` switches straight to `features`.
      '';
    };
    nixosModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      description = "Host-local NixOS modules.";
    };
    homeModules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.unspecified);
      default = {};
      description = "Per-user Home Manager modules, keyed by username.";
    };
  };

  derivedOptions = {
    # No default: a builder that forgets one of these fails loudly instead of
    # silently yielding an empty list.
    name = lib.mkOption {
      type = lib.types.str;
      description = "Host name, taken by discovery from hosts/<name>.nix or hosts/<name>/.";
    };
    osUsernames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Usernames NixOS creates for this host.";
    };
    hmUsernames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Host users that get a Home Manager configuration.";
    };
  };

  hostOptions = {
    options = hostFacts // authoringOptions;
  };

  flakeHostOptions = hostFacts // derivedOptions;
in {
  inherit hostOptions flakeHostOptions;
}
