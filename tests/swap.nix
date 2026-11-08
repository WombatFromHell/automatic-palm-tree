# nix-unit attributes for the nixos-swap feature: one module, two gated tiers
# (features.zswap.enable / features.zram.enable). Nothing is built.
#
# What is asserted is where the tuning lands, on both tiers, and that a tier's own overrides win
# over the shared defaults -- not that an enable flag is set. zram has no real host today
# (hosts/methyl-base/base.nix ships zswap), so its tier runs on a fixture host built through the
# same builder the flake uses. The prepare script's text is not asserted here; it is inline shell,
# so its shape is read off the host (ADR-f21cdaed28ee covers shipped-shell linting).
let
  s = import ./support.nix;
  inherit (s) lib;

  cfgOf = host: (s.builders.buildNixosConfigurations {${host.name} = host;}).${host.name}.config;

  # featureValues reach the Home Manager namespace only, so the NixOS-side enable gate goes
  # through nixosModules.
  fixture = name: mods:
    (s.fixtureHost true ["nixos-swap"] {})
    // {
      inherit name;
      homeModules.josh = [];
      nixosModules = mods;
    };

  zramCfg = cfgOf (fixture "zramtier" [
    {
      features = {
        zram.enable = true;
        zswap.enable = false;
      };
    }
  ]);
  zswapCfg = cfgOf (fixture "swaptier" [{features.zswap.swapfile.sizeMiB = 8192;}]);
  tunedCfg = cfgOf (
    fixture "tuned" [
      {
        features = {
          zram = {
            enable = true;
            sysctl."vm.swappiness" = 60;
            sysfs."/sys/kernel/mm/lru_gen/enabled" = "n";
          };
          zswap.enable = false;
        };
      }
    ]
  );
  # A btrfs root, so the subvolume rule's default is derived from the filesystem, and a host that
  # turns it off keeps the swapfile it already has.
  btrfsCfg = cfgOf (
    fixture "btrfs" [
      {
        fileSystems."/" = {
          device = "/dev/disk/by-label/root";
          fsType = "btrfs";
        };
      }
    ]
  );
  # XFS has no COW attribute to check; what it needs is a fully allocated file, so no btrfs tool
  # ships with the prepare script here.
  xfsCfg = cfgOf (
    fixture "xfs" [
      {
        fileSystems."/" = {
          device = "/dev/disk/by-label/root";
          fsType = "xfs";
        };
      }
    ]
  );
  # A mount under the swapfile's path shadows the root: the filesystem that decides the NOCOW and
  # subvolume rules is whichever mount holds the *closest* prefix, in either direction.
  swapMount = fsType: {
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/root";
        inherit fsType;
      };
      "/var/lib/swap" = {
        device = "/dev/disk/by-label/swap";
        fsType =
          if fsType == "btrfs"
          then "xfs"
          else "btrfs";
      };
    };
  };
  btrfsRootXfsSwapCfg = cfgOf (fixture "btrfs-root-xfs-swap" [(swapMount "btrfs")]);
  xfsRootBtrfsSwapCfg = cfgOf (fixture "xfs-root-btrfs-swap" [(swapMount "xfs")]);
  # Both tiers on one host is an authoring error. The fixtures declare a root filesystem and a
  # bootloader so that the false assertion below is the gate's, not a fixture artifact.
  root = {
    fileSystems."/" = {
      device = "/dev/disk/by-label/root";
      fsType = "btrfs";
    };
    boot.loader = {
      grub.enable = false;
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = false;
    };
  };
  bothCfg = cfgOf (fixture "both" [
    root
    {
      features = {
        zram.enable = true;
        zswap.enable = true;
      };
    }
  ]);
  oneTierCfg = cfgOf (fixture "one" [
    root
    {
      features = {
        zram.enable = true;
        zswap.enable = false;
      };
    }
  ]);
  gateMessage = "features.zswap.enable and features.zram.enable are mutually exclusive; pick one swap tier.";

  sysfsPaths = cfg: lib.attrNames cfg.systemd.tmpfiles.settings."10-swap";
  lru = "/sys/kernel/mm/lru_gen/enabled";
in {
  # ── the zram tier ──
  testHostGetsTheZramSetupUnit = {
    expr = zramCfg.systemd.services ? "systemd-zram-setup@";
    expected = true;
  };
  testTemplateUnitComesFromTheGeneratorPackage = {
    expr = s.hasPkg zramCfg.systemd.packages "zram-generator";
    expected = true;
  };
  testGeneratorConfigIsInstalled = {
    expr = builtins.hasAttr "systemd/zram-generator.conf" zramCfg.environment.etc;
    expected = true;
  };
  # Our own settings are the ones that ship, not NixOS defaults.
  testZramCompressionAlgorithmIsZstd = {
    expr = zramCfg.services.zram-generator.settings.zram0.compression-algorithm;
    expected = "zstd";
  };
  # Size is min(percentage of RAM, cap), so one default serves a 32GB host and a small VM, and a
  # host can move both numbers.
  testZramSizeFollowsPercentAndCap = {
    expr = [
      zramCfg.services.zram-generator.settings.zram0.zram-size
      (cfgOf (fixture "zramsize" [
        {
          features = {
            zram = {
              enable = true;
              ramPercent = 30;
              maxMiB = 4096;
            };
            zswap.enable = false;
          };
        }
      ])).services.zram-generator.settings.zram0.zram-size
    ];
    expected = ["min(ram * 25 / 100, 16384)" "min(ram * 30 / 100, 4096)"];
  };
  # zram is the swap tier, so zswap must not layer a second compression on top of it.
  testZramTierDisablesZswapAtTheKernelCommandLine = {
    expr = [
      (lib.elem "zswap.enabled=0" zramCfg.boot.kernelParams)
      (lib.elem "zswap.enabled=0" zswapCfg.boot.kernelParams)
    ];
    expected = [true false];
  };

  # ── tuning shared by both tiers, written once ──
  testSharedSwappinessOnBothTiers = {
    expr = [
      zramCfg.boot.kernel.sysctl."vm.swappiness"
      zswapCfg.boot.kernel.sysctl."vm.swappiness"
    ];
    expected = [180 180];
  };
  testSharedWatermarksOnBothTiers = {
    expr = [
      zramCfg.boot.kernel.sysctl."vm.watermark_scale_factor"
      zswapCfg.boot.kernel.sysctl."vm.watermark_scale_factor"
    ];
    expected = [125 125];
  };
  # The writeback knobs belong to a disk-backed swap device; compressed RAM has no disk to flush.
  testDirtyRatioOnlyOnTheZswapTier = {
    expr = [
      zswapCfg.boot.kernel.sysctl."vm.dirty_ratio"
      (zramCfg.boot.kernel.sysctl ? "vm.dirty_ratio")
    ];
    expected = [15 false];
  };
  testSharedSysfsWrittenOnBothTiers = {
    expr = [
      (lib.elem lru (sysfsPaths zramCfg))
      (lib.elem "/sys/kernel/mm/transparent_hugepage/enabled" (sysfsPaths zramCfg))
      (lib.elem lru (sysfsPaths zswapCfg))
    ];
    expected = [true true true];
  };
  testZswapPoolKnobsOnlyOnTheZswapTier = {
    expr = [
      (lib.elem "/sys/module/zswap/parameters/max_pool_percent" (sysfsPaths zswapCfg))
      (lib.elem "/sys/module/zswap/parameters/max_pool_percent" (sysfsPaths zramCfg))
    ];
    expected = [true false];
  };
  # A tier's own override beats the shared default on both surfaces.
  testTierOverrideBeatsSharedDefaults = {
    expr = [
      tunedCfg.boot.kernel.sysctl."vm.swappiness"
      tunedCfg.systemd.tmpfiles.settings."10-swap"."${lru}".w.argument
    ];
    expected = [60 "n"];
  };

  # ── the zswap tier's swapfile ──
  # boot.zswap is a global knob, not per-device: the tier turns it on and nixpkgs' swapDevices
  # carries the path and size.
  testZswapTierTurnsZswapOnAndShipsTheSwapfile = {
    expr = [
      zswapCfg.boot.zswap.enable
      (lib.head zswapCfg.swapDevices).size
    ];
    expected = [true 8192];
  };
  testSwapDeviceShipsOnTheZswapTierOnly = {
    expr = [
      (lib.head zswapCfg.swapDevices).device
      zramCfg.swapDevices
    ];
    expected = ["/var/lib/swap/swapfile" []];
  };
  # The prepare unit exists on the zswap tier, orders itself ahead of nixpkgs' own units, and
  # never re-runs or stops at a switch: a live swapfile is left alone, and nixpkgs' mkswap unit is
  # the one that re-creates it.
  testZswapPrepareUnitOnlyOnTheZswapTier = {
    expr = [
      (zswapCfg.systemd.services ? "zswap-prepare")
      (zramCfg.systemd.services ? "zswap-prepare")
      zswapCfg.systemd.services.zswap-prepare.before
      zswapCfg.systemd.services.zswap-prepare.restartIfChanged
      zswapCfg.systemd.services.zswap-prepare.stopIfChanged
    ];
    # systemd names a path unit by the escaped path with the leading slash dropped, so these
    # names are exactly the ones nixpkgs' swap module generates for the same device.
    expected = [true false ["var-lib-swap-swapfile.swap" "mkswap-var-lib-swap-swapfile.service"] false false];
  };
  # The tool set the prepare script ships with (e2fsprogs for chattr/lsattr, btrfs-progs for the
  # subvolume, findutils for the wipe) is chosen by the filesystem, but it is a build-time fact:
  # writeShellApplication bakes the PATH into the script, so nothing here can read it back. The
  # eval-visible rule is the subvolume default below; the script itself is shellchecked by nixpkgs
  # when the system builds (ADR-f21cdaed28ee).
  # The subvolume rule follows the filesystem the swapfile is written on, not any btrfs mount.
  testBtrfsSubvolumeDefaultFollowsTheFilesystem = {
    expr = [
      btrfsCfg.features.zswap.swapfile.btrfsSubvolume
      xfsCfg.features.zswap.swapfile.btrfsSubvolume
      zswapCfg.features.zswap.swapfile.btrfsSubvolume
      btrfsRootXfsSwapCfg.features.zswap.swapfile.btrfsSubvolume
      xfsRootBtrfsSwapCfg.features.zswap.swapfile.btrfsSubvolume
    ];
    expected = [true false false false true];
  };

  # ── the gate: one tier per host ──
  # NixOS raises collected assertions only when the system builds, so the gate is read back from
  # the assertion list instead of a build. Messages are forced only for the false entries; with
  # both tiers on, nixpkgs' own boot.zswap-vs-zramSwap refusal is false too, so this picks ours.
  testBothTiersTogetherIsRefused = {
    expr =
      lib.filter
      (a: a.message == gateMessage)
      (lib.filter (a: !a.assertion) bothCfg.assertions);
    expected = [
      {
        assertion = false;
        message = gateMessage;
      }
    ];
  };
  testOneTierPassesTheGate = {
    expr = lib.filter (a: !a.assertion) oneTierCfg.assertions;
    expected = [];
  };
  # The zswap tier is on by default -- the hosts these features shipped to never set it -- so a
  # zram host has to say `features.zswap.enable = false` beside `features.zram.enable = true`.
  testZswapTierIsOnByDefault = {
    expr = zswapCfg.features.zswap.enable;
    expected = true;
  };
}
