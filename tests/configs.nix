# Config suite: what one host actually ends up configured with. Every check forces an
# option value, never a derivation, so nothing is built.
#
# run.sh runs this file once per host with TEST_HOST set: three host configs in one eval
# need ~2.1GB, over the cap tests/nix-eval.sh puts on every eval, so one host per process.
let
  s = import ./support.nix;
  inherit (s) fs lib ck suite;
  out = s.flake.outputs;

  host = builtins.getEnv "TEST_HOST";
  cfg = out.nixosConfigurations.${host}.config;

  # `set ? name` only accepts a literal attribute path, so dynamic names go
  # through builtins.hasAttr.
  hasService = cfg: name: builtins.hasAttr name cfg.systemd.services;
  sysPkg = cfg: name: s.hasPkg cfg.environment.systemPackages name;
  hasParam = cfg: param: lib.elem param cfg.boot.kernelParams;
  hasNs = cfg: name: builtins.hasAttr name cfg.features;
  # An option path like "services.lact.enable", read as a value.
  optPath = lib.splitString ".";
  # Which kernel a host boots is a host-level choice: lib/features.nix allows exactly one
  # kernel-pinning feature per host.
  cachyosKernel = "linux-cachyos-latest-lto-x86_64-v3";

  # users.users.josh.shell is a derivation whose store path is hashed, so match
  # the name inside outPath rather than a prefix of the basename.
  hasFish = cfg: builtins.match ".*fish-[0-9].*" cfg.users.users.josh.shell.outPath != null;

  # Which package a feature hands its program option is a name and a pin, not a store path.
  # The derivation being *unwrapped* is proved by the nixGL check below (packages null makes
  # lib.nixGL.wrapGpu identity) and by tests/wrap.nix's identity-on-a-NixOS-fixture check.
  rawBrave = s.rawFeaturePkgs.brave;
  rawZed = s.rawFeaturePkgs.zed;
  homeCfg = cfg: cfg.home-manager.users.josh;

  # Gaming- and KDE-only signals, keyed by the hosts that own them. Presence is asserted on the
  # owner and absence on the other hosts, so a misspelled name fails the owner's check instead of
  # passing vacuously, and none of these reads environment.systemPackages (invariant 1: absence is
  # asserted one layer above the package list).
  featureOwners = {
    zswap = ["methyl" "methyl-nixos" "propyl"];
    dms = ["methyl" "methyl-nixos" "propyl"];
    korthos = ["methyl"];
    lsfg = ["methyl"];
    dmemcg-booster = ["methyl"];
    gnome = ["methyl-nixos"];
    qemu = ["methyl-nixos"];
    kait2en = ["propyl"];
  };
  # scx_loader and dmemcg-booster are systemd units only the gaming features declare, and
  # `services.scx-loader` is an option from nixpkgs-unstable, so it does not exist on a host that
  # does not enable the feature — the unit name is the absence signal.
  unitOwners = {
    dmemcg-booster = ["methyl"];
    scx_loader = ["methyl"];
  };
  optionOwners = {
    "programs.steam.enable" = ["methyl"];
    "services.lact.enable" = ["methyl"];
    "services.desktopManager.plasma6.enable" = ["methyl"];
  };

  # The layout terraform.sh reproduces, if this host declares one as a recipe (ADR-b77ec913151f).
  recipe =
    if builtins.pathExists ../hosts/${host}/terraform.json
    then builtins.fromJSON (builtins.readFile ../hosts/${host}/terraform.json)
    else {
      owns = false;
      partitions = [];
    };

  # Per-host expectations, straight from hosts/ and the profile layout. `kernel = null`
  # means "the kernel its own feature pins", compared against that feature's derivation.
  # Which host runs the Wayland watcher: its script shells out to bare `niri`, `pgrep` and
  # `nvtop`, so the unit may only name store paths and those tools must be installed for the
  # user whose session PATH the script reads. The option is the source of truth -- a host can
  # enable the niri feature without the watcher.
  watcherOn = cfg: (homeCfg cfg).features.niri.wl-watcher.enable;
  # Per-host facts no owner table can derive: which kernel the host's own feature pins, the
  # packages its profile promises, and the caches its features gate on. `kernel = null` means
  # "the kernel its own feature pins", compared against that feature's derivation.
  expect = {
    methyl = {
      kernel = cachyosKernel;
      packages = ["steam" "gamescope" "scx-loader" "lsfg-vk"];
      required = {nix-community = true;};
      mounts = {};
      efiVariables = true;
    };
    methyl-nixos = {
      kernel = cachyosKernel;
      packages = ["btrfs-progs" "snapper" "spice-vdagent"];
      # niri-spicy is on here, so its cache is required as well as the CachyOS one.
      required = {
        nix-community = true;
        wombatfromhell = true;
      };
      # The mount set the generated hardware-configuration.nix declares today, expressed as
      # (mountpoint -> subvol), which is what the layout must reproduce from disko (ADR-eaca61b8).
      # `{}` means fsLib's mkMounts still owns the mounts.
      mounts = {
        "/" = "@";
        "/home" = "@home";
        "/nix" = "@nix";
        "/var/log" = "@log";
        "/var/cache" = "@cache";
        "/var/lib/swap" = "@swap";
        "/.snapshots" = "@snapshots";
      };
      efiVariables = true;
    };
    propyl = {
      kernel = null;
      packages = ["fprintd"];
      required = {kait2en = true;};
      mounts = {};
      # Shared ESP with another OS: NixOS must not rewrite the firmware boot order.
      efiVariables = false;
    };
  };

  checks =
    if host == "" || !expect ? ${host}
    then throw "configs.nix: TEST_HOST must be one of ${lib.concatStringsSep ", " (lib.attrNames expect)}"
    else let
      e = expect.${host};
    in [
      # --- facts every host shares --------------------------------------------
      (ck "${host}: host name comes from the host record" (cfg.networking.hostName == host))
      (ck "${host}: timezone is set by the base profile" (cfg.time.timeZone == "America/Denver"))
      (ck "${host}: fish is the interactive shell for josh" (hasFish cfg))
      (ck "${host}: tailscale, podman, firefox and printing are on by default"
        (cfg.services.tailscale.enable && cfg.virtualisation.podman.enable && cfg.programs.firefox.enable && cfg.services.printing.enable))
      (ck "${host}: josh is a wheel member" (lib.elem "wheel" cfg.users.users.josh.extraGroups))
      (ck "${host}: nixos-defaults reaches the kernel command line" (hasParam cfg "kvm.ignore_msrs=1"))
      (ck "${host}: dms is on" (hasNs cfg "dms"))
      # Lix's evaluator costs ~450MB more per host config than upstream Nix (DESIGN.md "Which
      # evaluator"), so no host may opt back in. features/nixos-lix was deleted for this.
      (ck "${host}: nix.package is upstream Nix, not Lix" (cfg.nix.package.pname == "nix"))
      # features/hm-brave/nixos.nix sets this at mkOverride 1100, so it is a default the host
      # could override; presence here is what the profile's hm-brave actually delivers.
      (ck "${host}: yama restricts ptrace to descendants" (cfg.boot.kernel.sysctl."kernel.yama.ptrace_scope" == 1))
      # The hint is for a standalone host only: on NixOS the sysctl is set above, so an
      # integrated home config must not print one.
      (ck "${host}: its home config prints no ptrace hint"
        (!(lib.hasAttr "bravePtraceHint" (homeCfg cfg).home.activation)))

      # --- who owns the mounts, and what the firmware boot order is ------------
      # terraform.sh owns every drive this flake deploys onto (ADR-b77ec913151f), so no host declares
      # a disko layout: fsLib's mkMounts declares the mounts, and install.sh refuses a host that
      # declares a layout it has no installer for.
      (ck "${host}: no disko layout is declared" (((cfg.disko or {}).devices or {}) == {}))
      (ck "${host}: it has a root mount either way" (cfg.fileSystems."/" != null))

      # The recipe is the source of a host's partition mounts (ADR-62773e12d275): fileSystems is
      # derived from it, so device, fsType and options agree by construction. What stays worth
      # checking here is what a hand-written mount could still get wrong: every mount the config
      # declares is either one the recipe names, or a btrfs subvolume of the labelled root
      # terraform.sh creates. Anything else names a device this drive does not have.
      (ck "${host}: every mount is the recipe's or a subvolume of its root"
        (let
          derived = fs.mountsFromRecipe recipe;
          rootLabel = (lib.findFirst (p: p.mount == "/") null recipe.partitions or []).label;
          extra = lib.filterAttrs (m: f: !builtins.hasAttr m derived) cfg.fileSystems;
        in
          !builtins.pathExists ../hosts/${host}/terraform.json
          || (recipe.owns
            == cfg.flakeHost.ownsWholeDisk
            && lib.all
            (m:
              cfg.fileSystems.${m}.device
              == derived.${m}.device
              && cfg.fileSystems.${m}.fsType == derived.${m}.fsType)
            (lib.attrNames derived)
            && lib.all
            (f:
              f.fsType
              == "btrfs"
              && f.device == "/dev/disk/by-label/${rootLabel}"
              && lib.any (o: builtins.match "subvol=@.*" o != null) (f.options or []))
            (lib.attrValues extra))))
      (ck "${host}: systemd-boot is the loader, and EFI variables match the host"
        (cfg.boot.loader.systemd-boot.enable && cfg.boot.loader.efi.canTouchEfiVariables == e.efiVariables))
      (ck "${host}: its layout mounts the subvolume tree fsLib declared"
        ((lib.all
            (m:
              (cfg.fileSystems.${m} or {}).fsType
              == "btrfs"
              && lib.elem "subvol=${e.mounts.${m}}" ((cfg.fileSystems.${m} or {}).options or []))
            (lib.attrNames e.mounts))
          && (e.mounts == {} || cfg.fileSystems."/var/log".neededForBoot)
          && (e.mounts == {} || cfg.fileSystems."/boot".fsType == "vfat")))

      # --- nixGL disabled on this NixOS host ------------------------------------
      # features/hm-nixgl sets packages only when flakeHost.isNixOS is false, and Home Manager's
      # wrapper is a no-op on null. Asserted here rather than in tests/wrap.nix because this is
      # the real host config the profiles build. The "exactly one PATH entry" half stays in
      # tests/wrap.nix and tests/home.nix: counting home.packages forces every package's name,
      # which costs ~300MB per host for a fact the fixture already proves.
      (ck "${host}: nixGL packages are null for josh" (isNull (homeCfg cfg).targets.genericLinux.nixGL.packages))
      (ck "${host}: the GUI features hand their pinned packages to the program options"
        ((homeCfg cfg).programs.chromium.package.pname
          == rawBrave.pname
          && (homeCfg cfg).programs.chromium.package.version == rawBrave.version
          && (homeCfg cfg).programs.zed-editor.package.pname == rawZed.pname
          && (homeCfg cfg).programs.zed-editor.package.version == rawZed.version))

      (ck "${host}: wl-watcher execs store paths only, and installs what its script calls"
        (let
          u = (homeCfg cfg).systemd.user.services.wl-watcher or null;
        in
          # Non-watcher hosts must not grow the unit; forcing `home.packages` is skipped
          # there, which is what makes this check cheap on the other hosts.
          ((u != null) == watcherOn cfg)
          && (u
            == null
            || (lib.all
              (v: builtins.match "^-?/nix/store/.*" v != null)
              (lib.concatLists [
                (lib.toList u.Service.ExecStartPre)
                (lib.toList u.Service.ExecStart)
                (lib.toList u.Service.ExecStop)
              ])
              && s.hasPkg (homeCfg cfg).home.packages "procps"
              && s.hasPkg (homeCfg cfg).home.packages "nvtop"))))

      # --- this host's own profile effects -------------------------------------
      (ck "${host}: its packages are installed" (lib.all (p: sysPkg cfg p) e.packages))
      (ck "${host}: feature namespaces exist on their owning hosts only"
        (lib.all (f: hasNs cfg f == lib.elem host featureOwners.${f}) (lib.attrNames featureOwners)))
      # The namespace exists on every host now that one module declares both tiers, so the
      # backend claim is the enable gate itself -- and the tuning that tier owns (ADR-56394370887f)
      # has to arrive with it.
      (ck "${host}: its swap tier is zswap, and the tier's tuning arrived"
        (cfg.features.zswap.enable
          && !cfg.features.zram.enable
          && cfg.boot.kernel.sysctl."vm.swappiness" == 180
          && cfg.systemd.tmpfiles.settings."10-swap" ? "/sys/kernel/mm/lru_gen/enabled"))
      (ck "${host}: gaming systemd units exist on their owning hosts only"
        (lib.all (u: hasService cfg u == lib.elem host unitOwners.${u}) (lib.attrNames unitOwners)))
      (ck "${host}: gaming and KDE options are on for their owning hosts only"
        (lib.all (o: lib.getAttrFromPath (optPath o) cfg == lib.elem host optionOwners.${o})
          (lib.attrNames optionOwners)))
      # Which kernel a host boots is a host-level choice: lib/features.nix allows exactly one
      # kernel-pinning feature per host.
      (ck "${host}: it boots the kernel its feature pins"
        (
          if e.kernel == null
          then cfg.boot.kernelPackages.kernel == cfg.hardware.kait2en.kernelPackages.kernel
          else cfg.boot.kernelPackages.kernel.pname == e.kernel
        ))

      # --- cache wiring --------------------------------------------------------
      # A feature that gates on cache membership declares the cache required here, and
      # modules/caches.nix turns that into the substituters, keys and warnings.
      # Only the caches actually needed count: niri writes `required.wombatfromhell = false`
      # when its spicy option is off, and caches.nix filters false entries out.
      (ck "${host}: its features name the caches they need" (lib.filterAttrs (_: r: r) cfg.flakeCache.required == e.required))
      (ck "${host}: every required cache is enabled" cfg.flakeCache.ready)
    ];
in
  suite "configs ${host}" checks
