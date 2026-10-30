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
  # An option path read as a value: `["services" "lact" "enable"]` -> bool.
  optFalse = cfg: path: lib.getAttrFromPath path cfg == false;
  optTrue = cfg: path: lib.getAttrFromPath path cfg == true;
  # Which kernel a host boots is a host-level choice: lib/features.nix allows exactly one
  # kernel-pinning feature per host.
  cachyosKernel = "linux-cachyos-latest-lto-x86_64-v3";

  # users.users.josh.shell is a derivation whose store path is hashed, so match
  # the name inside outPath rather than a prefix of the basename.
  hasFish = cfg: builtins.match ".*fish-[0-9].*" cfg.users.users.josh.shell.outPath != null;

  # Which package a feature hands its program option is a name and a pin, not a store path.
  # The derivation being *unwrapped* is proved by the nixGL check below (packages null makes
  # lib.nixGL.wrapGpu identity) and by tests/wrap.nix's identity-on-a-NixOS-fixture check.
  rawBrave = s.pkgs.unstable.callPackage ../features/hm-brave/_package.nix {};
  rawZed = (s.pkgs.callPackage ../features/hm-zed/_package.nix {}).noFHS;
  homeCfg = cfg: cfg.home-manager.users.josh;

  # Gaming- and KDE-only effects must not leak onto the workstation or laptop. Asserted one
  # layer above the package list: mapping `pname` over environment.systemPackages forces every
  # package (~500MB per host), while the namespace, systemd unit and program option the same
  # features write answer the same question for a few option values.
  gamingStack = {
    absentFeatures = ["korthos" "lsfg" "dmemcg-booster"];
    # scx_loader and dmemcg-booster are systemd units only the gaming features declare, and
    # `services.scx-loader` is an option from nixpkgs-unstable, so it does not exist on a host
    # that does not enable the feature — the unit name is the absence signal.
    absentServices = ["dmemcg-booster" "scx_loader"];
    absentOptions = [
      ["programs" "steam" "enable"]
      ["services" "lact" "enable"]
      ["services" "desktopManager" "plasma6" "enable"]
    ];
  };

  # Per-host expectations, straight from hosts/ and the profile layout. `kernel = null`
  # means "the kernel its own feature pins", compared against that feature's derivation.
  expect = {
    methyl = {
      kernel = cachyosKernel;
      features = ["zswap" "korthos" "dms"];
      absentFeatures = ["kait2en" "gnome" "qemu"];
      packages = ["steam" "gamescope" "scx-loader" "lsfg-vk"];
      # The positive side of the gaming-stack signals, so the absence assertions below are
      # not vacuous: `scx_loader` really is the unit nixos-scx declares, and plasma6 really
      # is the option nixos-kde turns on.
      services = ["dmemcg-booster" "scx_loader"];
      options = [["services" "desktopManager" "plasma6" "enable"]];
      absentServices = [];
      absentOptions = [];
      required = {nix-community = true;};
    };
    methyl-nixos = {
      kernel = cachyosKernel;
      features = ["zswap" "gnome" "qemu" "dms"];
      absentFeatures = ["kait2en"] ++ gamingStack.absentFeatures;
      packages = ["btrfs-progs" "snapper" "spice-vdagent"];
      inherit (gamingStack) absentServices absentOptions;
      services = [];
      options = [];
      # niri-spicy is on here, so its cache is required as well as the CachyOS one.
      required = {
        nix-community = true;
        wombatfromhell = true;
      };
    };
    propyl = {
      kernel = null;
      features = ["kait2en" "dms"];
      absentFeatures = ["korthos" "gnome" "qemu"] ++ gamingStack.absentFeatures;
      packages = ["fprintd"];
      inherit (gamingStack) absentServices absentOptions;
      services = [];
      options = [];
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

      # --- this host's own profile effects -------------------------------------
      (ck "${host}: its features are enabled" (lib.all (f: hasNs cfg f) e.features))
      (ck "${host}: another host's features are absent" (lib.all (f: !hasNs cfg f) e.absentFeatures))
      (ck "${host}: its packages are installed" (lib.all (p: sysPkg cfg p) e.packages))
      (ck "${host}: another host's systemd units are absent" (lib.all (u: !hasService cfg u) e.absentServices))
      (ck "${host}: another host's program and service options stay off"
        (lib.all (p: optFalse cfg p) e.absentOptions))
      (ck "${host}: its services are enabled" (lib.all (svc: hasService cfg svc) e.services))
      (ck "${host}: its program and service options are on" (lib.all (p: optTrue cfg p) e.options))
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
      (ck "${host}: substituters and keys are derived from the cache list"
        (lib.length cfg.nix.settings.extra-substituters
          == lib.length cfg.flakeCache.enable
          && lib.length cfg.nix.settings.extra-trusted-public-keys == lib.length cfg.flakeCache.enable))
    ];
in
  suite "configs ${host}" checks
