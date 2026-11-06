# nix-unit attributes for features/nixos-disko/nixos.nix: a `gpt` layout may only be declared by
# a host that owns its whole drive, and a host with no layout keeps its fsLib-built mounts.
# Bare eval — no NixOS, no build. disko's own module is stubbed out (specialArgs carry an empty
# module in its place), so the guard is read back without forcing the options disko writes.
let
  core = import ./support.nix;
  inherit (core) lib failingAssertions;

  stubs = {
    options = {
      flakeHost = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        default = {};
      };
      disko = {
        devices = lib.mkOption {
          type = lib.types.attrsOf lib.types.unspecified;
          default = {};
        };
        enableConfig = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };
    };
  };

  eval = owns: disk:
    core.bareEval [stubs ../features/nixos-disko/nixos.nix] {
      flakeHost = {
        name = "fixture";
        ownsWholeDisk = owns;
      };
      disko.devices = {inherit disk;};
    } {
      inputs.disko.nixosModules.disko = {};
    };

  gpt = {
    main = {
      device = "/dev/vda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {};
      };
    };
  };

  # The converging shape: btrfs content guards with blkid and `btrfs subvolume show`, so it never
  # touches partitions it did not create.
  btrfs = {
    main = {
      device = "/dev/vda";
      type = "disk";
      content = {
        type = "btrfs";
        subvolumes = {};
      };
    };
  };

  unownedGpt = failingAssertions (eval false gpt);
  noLayout = eval false {};
in {
  testGptLayoutWithoutDriveOwnershipFailsOneAssertion = {
    expr = builtins.length unownedGpt;
    expected = 1;
  };
  # The message has to name both the disk shape and the fact that clears it.
  testGptGuardNamesTheFactThatClearsIt = {
    expr = lib.hasInfix "ownsWholeDisk" (builtins.head unownedGpt).message;
    expected = true;
  };
  testGptLayoutWithDriveOwnershipPasses = {
    expr = failingAssertions (eval true gpt);
    expected = [];
  };
  testBtrfsLayoutNeedsNoDriveOwnership = {
    expr = failingAssertions (eval false btrfs);
    expected = [];
  };
  # With no devices declared, disko's `fileSystems` write is switched off, so a host that opted
  # in without a layout keeps the mounts fsLib built for it.
  testNoLayoutTurnsDiskoConfigOff = {
    expr = noLayout.disko.enableConfig;
    expected = false;
  };
  testLayoutLeavesDiskoConfigOn = {
    expr = (eval true btrfs).disko.enableConfig;
    expected = true;
  };
}
