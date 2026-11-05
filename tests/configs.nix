# Config suite: what one host actually ends up configured with. Every check forces an
# option value, never a derivation, so nothing is built.
#
# run.sh runs this file once per host with TEST_HOST set: three host configs in one eval
# need ~2.1GB, over the cap tests/nix-eval.sh puts on every eval, so one host per process.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;
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
    };
    methyl-nixos = {
      kernel = cachyosKernel;
      packages = ["btrfs-progs" "snapper" "spice-vdagent"];
      # niri-spicy is on here, so its cache is required as well as the CachyOS one.
      required = {
        nix-community = true;
        wombatfromhell = true;
      };
    };
    propyl = {
      kernel = null;
      packages = ["fprintd"];
      required = {kait2en = true;};
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
