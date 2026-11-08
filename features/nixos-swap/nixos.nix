# One swap feature, two tiers. `features.zswap.enable` selects disk-backed zswap,
# `features.zram.enable` selects compressed-RAM zram; exactly one may be on, because both
# compress and layering them compresses twice. The memory-pressure tuning is written once,
# here, and a tier's own `sysctl`/`sysfs` options are merged over those defaults.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  zswap = config.features.zswap;
  zram = config.features.zram;
  zswapTier = zswap.enable;
  zramTier = zram.enable;

  swapDevice = zswap.swapfile.path;
  swapDir = dirOf swapDevice;
  swapMiB = zswap.swapfile.sizeMiB;
  swapUnit = utils.escapeSystemdPath swapDevice;
  # nixpkgs names its creation unit after the device with backslashes stripped.
  mkswapUnit = "mkswap-${lib.replaceStrings ["\\"] [""] swapUnit}";

  # Read-only use of `config.fileSystems`: nixpkgs' filesystems module already feeds
  # boot.supportedFilesystems from the declared mounts, and writing it here while reading that
  # option back is the cycle that overflows the stack.
  mounts = lib.filterAttrs (_: fs: fs.fsType != null) config.fileSystems;

  # The filesystem the swapfile actually sits on, by the longest matching mount point. Only this
  # one decides the allocation rule: NOCOW is a btrfs property, so a host with a btrfs / and an
  # XFS or ext4 swap path must not be held to it.
  swapFs =
    lib.foldl'
    (best: fs:
      if !lib.hasPrefix fs.mountPoint swapDevice
      then best
      else if best == null || builtins.stringLength fs.mountPoint > builtins.stringLength best.mountPoint
      then fs
      else best)
    null
    (lib.attrValues mounts);
  onBtrfs = swapFs != null && swapFs.fsType == "btrfs";
  swapSubvolume = onBtrfs && zswap.swapfile.btrfsSubvolume;

  # ── tuning shared by both tiers ──
  sysctlBase = {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
  };
  sysfsBase = {
    "/sys/kernel/mm/lru_gen/enabled" = "y";
    "/sys/kernel/mm/transparent_hugepage/enabled" = "madvise";
  };
  # The writeback knobs and the zswap pool only mean something to a disk-backed swap device;
  # compressed RAM has no disk to flush to.
  sysctl =
    sysctlBase
    // lib.optionalAttrs zswapTier {
      "vm.dirty_ratio" = 15;
      "vm.dirty_background_ratio" = 5;
      "vm.vfs_cache_pressure" = 100;
    }
    // (
      if zswapTier
      then zswap.sysctl
      else zram.sysctl
    );
  sysfs =
    sysfsBase
    // lib.optionalAttrs zswapTier {
      "/sys/module/zswap/parameters/compressor" = "zstd";
      "/sys/module/zswap/parameters/max_pool_percent" = "30";
      "/sys/module/zswap/parameters/accept_threshold_percent" = "80";
      "/sys/module/zswap/parameters/shrinker_enabled" = "Y";
    }
    // (
      if zswapTier
      then zswap.sysfs
      else zram.sysfs
    );

  # The swapfile is prepared, not managed: creation stays nixpkgs' job (its mkswap unit runs
  # `btrfs filesystem mkswapfile` on btrfs and dd + mkswap everywhere else). This unit marks the
  # swap directory NOCOW, wipes the dedicated btrfs subvolume when the file must be rebuilt, and
  # refuses a file the kernel cannot use -- and never touches one that is already active, so a
  # resize is paid at the switch, where nixpkgs recreates the file, not here.
  prepare = pkgs.writeShellApplication {
    name = "zswap-prepare";
    runtimeInputs =
      [pkgs.coreutils pkgs.gawk]
      ++ lib.optionals onBtrfs [pkgs.e2fsprogs pkgs.findutils]
      ++ lib.optionals swapSubvolume [pkgs.btrfs-progs];
    text = ''
      dir=${lib.escapeShellArg swapDir}
      file=${lib.escapeShellArg swapDevice}
      want=$(( ${toString swapMiB} * 1024 * 1024 ))

      swap_active() { awk -v f="$file" 'NR>1 && $1==f {found=1} END{exit !found}' /proc/swaps; }

      if swap_active; then
        echo "swapfile $file is active; leaving it alone"
        exit 0
      fi

      # Btrfs-specific subvolume management for the swapfile's parent directory
      ${lib.optionalString swapSubvolume ''
        # The subvolume is dedicated to swap and gets wiped when the file is rebuilt, so a path
        # that shares a subvolume with other data would be a data-loss bug.
        if [ "$dir" = "/" ]; then
          echo "swapfile path sits in the filesystem root subvolume; refusing to wipe it" >&2
          exit 1
        fi
        if ! btrfs subvolume show "$dir" >/dev/null 2>&1; then
          if [ -e "$dir" ]; then
            echo "$dir exists but is not a subvolume; replacing it" >&2
            rm -f "$file"
            rmdir "$dir"
          fi
          btrfs subvolume create "$dir"
        fi
      ''}

      # Ensures the directory exists on non-Btrfs filesystems as well
      mkdir -p "$dir"

      if [ -e "$file" ]; then
        reuse=1
        size=$(stat -c %s "$file")
        alloc=$(( $(stat -c %b "$file") * 512 ))
        bad=""
        # swapon(8): a swap file must not contain holes, and the kernel writes to it without the
        # filesystem's help. On XFS that means the whole file must be allocated -- a file created
        # by truncate(1) or cp(1) reports fewer blocks than its size and is rejected. A file
        # preallocated with fallocate(1) is accepted on XFS only since Linux 4.18; nixpkgs creates
        # it with dd, which is fully allocated on every filesystem, so an under-allocated file is
        # unusable wherever it sits.
        [ "$size" -ne "$want" ] && bad="size $size, want $want"
        [ "$alloc" -lt "$size" ] && bad="not fully allocated ($alloc of $size bytes)"
        ${lib.optionalString onBtrfs ''
        # btrfs(5): swap files need the NOCOW attribute, or the file location moves under COW.
        attrs=$(lsattr -d "$file" | awk '{print $1}')
        case "$attrs" in *C*) ;; *) bad="missing NOCOW attribute" ;; esac
      ''}
        if [ -n "$bad" ]; then
          echo "swapfile unusable: $bad" >&2
          reuse=0
        fi
      else
        reuse=0
      fi

      # A swapfile needs NOCOW, and chattr +C on the directory makes every file created in it
      # inherit that. It is only takeable while the directory is empty, and btrfs cannot set it on
      # a file that already holds data (btrfs-man5), so the dedicated subvolume is wiped before the
      # swapfile is allocated fresh -- nixpkgs' mkswap unit runs after this one.
      ${lib.optionalString swapSubvolume ''
        if [ "$reuse" = 0 ]; then
          find "$dir" -mindepth 1 -delete
        fi
        # Idempotent. If it fails, 'btrfs filesystem mkswapfile' still sets NODATACOW on the file.
        chattr +C "$dir" || echo "zswap-prepare: chattr +C failed on $dir" >&2
      ''}

      if [ "$reuse" = 0 ]; then
        rm -f "$file"
      fi
    '';
  };
in {
  options.features.zram = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use compressed RAM (zram) as the swap tier instead of a disk-backed swapfile.";
    };

    ramPercent = lib.mkOption {
      type = lib.types.ints.between 1 200;
      default = 25;
      description = ''
        Uncompressed zram device size as a percentage of RAM. The device only
        consumes RAM for data actually stored in it (roughly 1/2-1/3 of the
        stored size with zstd), so oversizing costs nothing until it is used.
      '';
    };

    maxMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16384;
      description = "Upper bound on the uncompressed zram device size, in MiB.";
    };

    algorithm = lib.mkOption {
      type = lib.types.str;
      default = "zstd";
      description = "zram compression algorithm (zstd = best ratio, lz4 = lowest CPU).";
    };

    priority = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Swap priority. Keep above any disk-backed swap so zram fills first.";
    };

    residentLimitMiB = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Hard cap on the real RAM the zram device may occupy, in MiB. Null
        leaves it uncapped. Useful if incompressible data could otherwise
        crowd out your applications.
      '';
    };

    sysctl = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [lib.types.int lib.types.str]);
      default = {};
      example = {"vm.swappiness" = 100;};
      description = "Extra or overriding sysctls, merged over the shared defaults.";
    };

    sysfs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra or overriding sysfs values (full paths), merged over the shared defaults.";
    };
  };

  options.features.zswap = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use a disk-backed swapfile with zswap compression -- the tier these hosts ship.";
    };

    swapfile = {
      path = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/swap/swapfile";
        description = "Absolute path of the swapfile.";
      };

      sizeMiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8192;
        description = ''
          Swapfile size in MiB. Changing it makes nixpkgs' mkswap unit recreate the
          file at the next activation, while the old swap is still active, so a
          resize is a switch-time cost, not a boot-time one.
        '';
      };

      btrfsSubvolume = lib.mkOption {
        type = lib.types.bool;
        # derived from the filesystem the swapfile sits on, not from any btrfs mount
        default = onBtrfs;
        description = ''
          Keep the swapfile's parent directory as a dedicated Btrfs subvolume, marked NOCOW with
          `chattr +C` and wiped whenever the swapfile is rebuilt. The directory must hold nothing
          else. Disable if the path is not on Btrfs or not in its own directory.
        '';
      };
    };

    sysctl = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [lib.types.int lib.types.str]);
      default = {};
      example = {"vm.swappiness" = 150;};
      description = "Extra or overriding sysctls, merged over the shared defaults.";
    };

    sysfs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {"/sys/module/zswap/parameters/compressor" = "lz4";};
      description = "Extra or overriding sysfs values written at boot via tmpfiles.d, merged over the shared defaults.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(zswapTier && zramTier);
          message = "features.zswap.enable and features.zram.enable are mutually exclusive; pick one swap tier.";
        }
        {
          assertion = !zswapTier || lib.hasPrefix "/" swapDevice;
          message = "features.zswap.swapfile.path must be an absolute path.";
        }
      ];
    }

    # Tuning arrives with whichever tier is on, at mkDefault so a host can still name its own.
    (lib.mkIf (zswapTier || zramTier) {
      # Per key, not the whole attrset: nixpkgs declares a default attrset here at the same
      # priority, and an attrset assignment at mkDefault loses to it.
      boot.kernel.sysctl = lib.mapAttrs (_: value: lib.mkDefault value) sysctl;
      systemd.tmpfiles.settings."10-swap" =
        lib.mapAttrs
        (_path: value: {w.argument = value;})
        sysfs;
    })

    (lib.mkIf zramTier {
      # zram is the swap tier, so make sure zswap isn't layering on top of it.
      boot.kernelParams = ["zswap.enabled=0"];
      zramSwap.enable = true;
      # Override the NixOS-generated settings with our own native zram-generator syntax
      services.zram-generator.settings = lib.mkForce {
        zram0 =
          {
            zram-size = "min(ram * ${toString zram.ramPercent} / 100, ${toString zram.maxMiB})";
            compression-algorithm = zram.algorithm;
            swap-priority = zram.priority;
          }
          // lib.optionalAttrs (zram.residentLimitMiB != null) {
            zram-resident-limit = zram.residentLimitMiB;
          };
      };
    })

    (lib.mkIf zswapTier {
      boot.zswap.enable = true;
      swapDevices = [
        {
          device = swapDevice;
          size = swapMiB;
        }
      ];

      systemd.services.zswap-prepare = {
        description = "Prepare the swapfile location";
        wantedBy = ["${swapUnit}.swap"];
        before = ["${swapUnit}.swap" "${mkswapUnit}.service"];
        # Do not re-run (or stop) during a switch; this is boot-time preparation.
        restartIfChanged = false;
        stopIfChanged = false;
        # Same anti-cycle rule as nixpkgs' mkswap unit: wantedBy a .swap unit
        # means no default dependencies.
        unitConfig = {
          DefaultDependencies = false;
          RequiresMountsFor = [swapDir];
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe prepare;
        };
      };
    })
  ];
}
