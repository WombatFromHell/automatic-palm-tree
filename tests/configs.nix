# Config suite: what each host actually ends up configured with. Every check
# forces an option value, never a derivation, so nothing is built. ~12s.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;
  out = s.flake.outputs;

  methyl = out.nixosConfigurations.methyl.config;
  ws = out.nixosConfigurations.methyl-nixos.config;
  propyl = out.nixosConfigurations.propyl.config;

  pkgNames = cfg: map (p: p.pname or p.name) cfg.environment.systemPackages;
  # `set ? name` only accepts a literal attribute path, so dynamic names go
  # through builtins.hasAttr.
  hasService = cfg: name: builtins.hasAttr name cfg.systemd.services;
  hasPkg = cfg: name: lib.elem name (pkgNames cfg);
  hasParam = cfg: param: lib.elem param cfg.boot.kernelParams;
  hasNs = cfg: name: builtins.hasAttr name cfg.features;
  # The kernel name features/nixos-cachyos pins, asserted per host below.
  cachyosKernel = "linux-cachyos-latest-lto-x86_64-v3";

  # users.users.josh.shell is a derivation whose store path is hashed, so match
  # the name inside outPath rather than a prefix of the basename.
  hasFish = cfg: builtins.match ".*fish-[0-9].*" cfg.users.users.josh.shell.outPath != null;

  # Gaming- and KDE-only effects must not leak onto the workstation or laptop.
  methylOnlyPkgs = ["steam" "gamescope" "scx-loader" "lsfg-vk" "dmemcg-booster" "plasma-desktop"];

  checks = [
    # --- facts every host shares --------------------------------------------
    (ck "host names come from the host record"
      ((methyl.networking.hostName == "methyl") && (ws.networking.hostName == "methyl-nixos") && (propyl.networking.hostName == "propyl")))
    (ck "timezone is set by the base profile on every host"
      (lib.all (cfg: cfg.time.timeZone == "America/Denver") [methyl ws propyl]))
    (ck "fish is the interactive shell for josh on every host"
      (lib.all hasFish [methyl ws propyl]))
    (ck "tailscale, podman, firefox and printing are on by default everywhere"
      (lib.all
        (cfg: cfg.services.tailscale.enable && cfg.virtualisation.podman.enable && cfg.programs.firefox.enable && cfg.services.printing.enable)
        [methyl ws propyl]))
    (ck "josh is a wheel member on every NixOS host"
      (lib.all (cfg: lib.elem "wheel" cfg.users.users.josh.extraGroups) [methyl ws propyl]))

    # --- profile-specific effects -------------------------------------------
    (ck "gaming profile adds its services and packages to methyl only"
      ((hasService methyl "dmemcg-booster")
        && (hasPkg methyl "steam")
        && (hasPkg methyl "scx-loader")
        && (hasPkg methyl "gamescope")
        && (hasPkg methyl "lsfg-vk")))
    (ck "methyl-only packages stay on methyl"
      (lib.all (cfg: !(lib.any (n: hasPkg cfg n) methylOnlyPkgs)) [ws propyl]))
    (ck "zswap reaches the kernel command line on methyl and methyl-nixos"
      ((hasParam methyl "zswap.enabled=1") && (hasParam ws "zswap.enabled=1") && (hasNs methyl "zswap") && (hasNs ws "zswap")))
    (ck "nixos-defaults reaches every NixOS host"
      (lib.all (cfg: hasParam cfg "kvm.ignore_msrs=1") [methyl ws propyl]))
    # Which kernel a host boots is a host-level choice: lib/features.nix allows exactly one
    # kernel-pinning feature per host, so propyl's boot kernel must be KaiT2en's own derivation.
    (ck "each host boots the kernel its feature pins"
      ((methyl.boot.kernelPackages.kernel.pname == cachyosKernel)
        && (ws.boot.kernelPackages.kernel.pname == cachyosKernel)
        && (propyl.boot.kernelPackages.kernel == propyl.hardware.kait2en.kernelPackages.kernel)))
    (ck "workstation-only features: gnome, btrfs, qemu"
      ((hasNs ws "gnome") && (hasNs ws "qemu") && (hasPkg ws "btrfs-progs") && (hasPkg ws "snapper") && (hasPkg ws "spice-vdagent")))
    (ck "kait2en is laptop-only"
      ((hasNs propyl "kait2en") && (hasPkg propyl "fprintd") && !(hasNs methyl "kait2en") && !(hasNs ws "kait2en")))
    (ck "kde is methyl-only" ((hasNs methyl "korthos") && !(hasNs ws "korthos") && !(hasNs propyl "korthos")))
    (ck "dms is on every graphical host" (lib.all (cfg: hasNs cfg "dms") [methyl ws propyl]))

    # --- cache wiring --------------------------------------------------------
    (ck "every host substitutes from the caches its features need"
      (lib.all (cfg: cfg.flakeCache.ready) [methyl ws propyl]))
    # No host may produce a configuration warning: a stale option write or a cache
    # a feature needs but the host does not substitute from shows up here.
    (ck "every host produces no configuration warnings"
      (lib.all (cfg: cfg.warnings == []) [methyl ws propyl]))
    (ck "the cache list is the registry default on every host"
      (lib.all (cfg: cfg.flakeCache.enable == methyl.flakeCache.enable) [ws propyl]))
    (ck "substituters and keys are derived from that list"
      ((lib.length methyl.nix.settings.extra-substituters == lib.length methyl.flakeCache.enable)
        && (lib.length methyl.nix.settings.extra-trusted-public-keys == lib.length methyl.flakeCache.enable)))
    # Assertions are data, not throws: they only stop a switch when built, so the
    # eval-level check is "some assertion fails and names the cache".
    (ck "a required cache outside the registry fails an assertion"
      (lib.any
        (a: !a.assertion && lib.hasPrefix "flakeCache.required names unknown cache(s)" a.message)
        (out.nixosConfigurations.propyl.extendModules {
          modules = [{flakeCache.required.bogus-cache = true;}];
        }).config.assertions))
  ];
in
  suite "configs" checks
