{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.features.zswap;

  # Read-only use of `config.fileSystems` (declaring it here while reading
  # boot.supportedFilesystems would recurse infinitely).
  btrfsFs = lib.filterAttrs (_: fs: fs.fsType == "btrfs") config.fileSystems;
  onBtrfs = btrfsFs != {};

  swapMiB = 4096;
  swapDevice =
    if onBtrfs
    then "/var/lib/swap/swapfile"
    else "/var/lib/swapfile";
  swapDir = dirOf swapDevice;

  swapUnit = utils.escapeSystemdPath swapDevice;
  # nixpkgs names its creation unit after the device with backslashes stripped.
  mkswapUnit = "mkswap-${lib.replaceStrings ["\\"] [""] swapUnit}";

  prepare = pkgs.writeShellApplication {
    name = "zswap-prepare";
    runtimeInputs = with pkgs; [btrfs-progs coreutils e2fsprogs gnugrep gawk];
    text = ''
      dir=${lib.escapeShellArg swapDir}
      file=${lib.escapeShellArg swapDevice}
      want=$(( ${toString swapMiB} * 1024 * 1024 ))

      swap_active() { awk -v f="$file" 'NR>1 && $1==f {found=1} END{exit !found}' /proc/swaps; }

      # Never touch a swapfile that is in use: swapoff would page everything
      # back into RAM, which is the thing a small machine cannot afford.
      if swap_active; then
        echo "swapfile $file is active; leaving it alone"
        exit 0
      fi

      ${lib.optionalString onBtrfs ''
        # Must be a real subvolume (so it is skipped by snapshots of the parent),
        # not a plain directory.
        if ! btrfs subvolume show "$dir" >/dev/null 2>&1; then
          if [ -e "$dir" ]; then
            echo "$dir exists but is not a subvolume; replacing it"
            rm -f "$file"
            rmdir "$dir"   # fails loudly if something else lives there
          fi
          btrfs subvolume create "$dir"
        fi
      ''}

      mkdir -p "$dir"

      # Delete anything nixpkgs' mkswap unit would silently accept but swapon
      # would mishandle; it recreates the file in the right form.
      if [ -e "$file" ]; then
        size=$(stat -c %s "$file")
        alloc=$(( $(stat -c %b "$file") * 512 ))
        bad=""
        [ "$size" -ne "$want" ] && bad="size $size, want $want"
        [ "$alloc" -lt "$size" ] && bad="sparse ($alloc of $size bytes allocated)"
        ${lib.optionalString onBtrfs ''
        lsattr -d "$file" | awk '{print $1}' | grep -q C || bad="missing NOCOW attribute"
      ''}
        if [ -n "$bad" ]; then
          echo "removing unusable swapfile: $bad"
          rm -f "$file"
        fi
      fi
    '';
  };
in {
  options.features.zswap.enable =
    lib.mkEnableOption "zswap-backed swap with memory pressure tuning"
    // {default = true;};

  config = lib.mkIf cfg.enable {
    boot = {
      zswap.enable = true;
      supportedFilesystems = lib.mkIf onBtrfs ["btrfs"];
      kernel.sysctl = {
        "vm.swappiness" = 150;
        "vm.vfs_cache_pressure" = 50;
        "vm.watermark_boost_factor" = 0;
        "vm.watermark_scale_factor" = 125;
      };
    };

    # Keep `size` constant: changing it makes nixpkgs recreate the file,
    # which means a swapoff during the switch.
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
        RequiresMountsFor = ["/var/lib"];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe prepare;
      };
    };
  };
}
