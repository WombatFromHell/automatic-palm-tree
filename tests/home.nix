# Home suite: the standalone (non-NixOS) host, evaluated through the flake's own
# outputs. No build. ~3s.
#
# Expectations here are derived from the host's own module and from what the configuration
# actually installs, never from a list of features this host happens to enable. A host gaining
# or losing a feature stays green; what is pinned is the shape of what a feature does.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;

  hm = s.flake.outputs.homeConfigurations."josh@methyl-bazzite";
  cfg = hm.config;

  # The host's own module, called the way the loader calls it: its feature list and its
  # hand-written home module are the expectations, so neither is duplicated here.
  host = (import ../hosts/methyl-bazzite.nix) {inherit (s) hostLib;};

  # The derivations our feature _package.nix files produce, called exactly as production does
  # (support.nix's rawFeaturePkgs). Only pname and outPath are forced, so nothing is built.
  raw = s.rawFeaturePkgs;
  rawPkgs = lib.attrValues raw;

  # Two features no real host enables (nixos-zram's counterpart here: hm-dcal and hm-ghostty).
  # A fixture host asks for them through the same builder, so the effect is what gets checked.
  # hm-nixgl is part of the ask: ghostty's GPU wrapper is a no-op without it, exactly as on NixOS.
  # dcal is resolved the way features/hm-dcal/home.nix resolves it.
  dcal = s.pkgs.unstable.flakePackages.dcal.${s.pkgs.unstable.stdenv.hostPlatform.system}.default;
  fx = s.hmCfg (s.fixtureHost false ["hm-dcal" "hm-ghostty" "hm-nixgl"] {});
  fxInstalled = pkg: s.pkgNamed fx.home.packages (pkg.pname or pkg.name);

  # The copies of one derivation that reached PATH. Absence is allowed — which GUI features a
  # host enables is the host's business — so the companion check below keeps this from going
  # vacuous on a host with no GUI feature at all.
  installed = pkg: s.pkgNamed cfg.home.packages (pkg.pname or pkg.name);
  wrappedOnce = pkg: let
    ps = installed pkg;
  in
    ps
    == []
    || (lib.length ps == 1 && (lib.head ps).outPath != pkg.outPath);

  # Home Manager's own module set cannot be evaluated standalone (its
  # modules/default.nix needs the builder's `configuration` argument), and every
  # feature module the profiles enable is already imported by the host config, so
  # re-adding one is a duplicate declaration. Feature-module coverage therefore
  # comes from the real configuration below, plus the loader's path resolution
  # (tests/loader.nix).

  checks = [
    (ck "the standalone host produces exactly one home configuration"
      (lib.attrNames s.flake.outputs.homeConfigurations == ["josh@methyl-bazzite"]))
    (ck "username and home directory come from the builder"
      ((cfg.home.username == "josh") && (cfg.home.homeDirectory == "/home/josh")))
    (ck "genericLinux is the target for a non-NixOS host" cfg.targets.genericLinux.enable)

    # A feature attr that exists but is disabled means the module was imported and then switched
    # off, which is a config bug rather than a host choice; and every `hm-` entry the host lists
    # must resolve to a home module, so a typo or a feature dir without a home.nix cannot be
    # dropped silently by the loader. Attrs without an `enable` (hm-nixgl has only `wrapper`)
    # are always active, so they count as enabled.
    (ck "every feature the configuration declares is enabled"
      (lib.all (f: cfg.features.${f}.enable or true) (lib.attrNames cfg.features)))
    (ck "the host's home features all resolve to a home module"
      (let
        hmFeatures = lib.filter (f: lib.hasPrefix "hm-" f) (host.features or []);
      in
        hmFeatures
        != []
        && lib.length (s.features.resolveFeaturePaths hmFeatures "home") == lib.length hmFeatures))

    # The host's own module promises packages; what it promises is what this checks, so editing
    # that module cannot make the suite red. Modules are called with the loader's package set --
    # a module needing more of the builder's extra args would throw loudly here.
    (ck "host-authored home modules reach the configuration"
      (let
        authored = lib.concatMap (m: (m {inherit (s) pkgs;}).home.packages or []) (host.homeModules.josh or []);
      in
        authored != [] && lib.all (p: lib.elem p cfg.home.packages) authored))
    (ck "profile features reach the configuration" (lib.all (s.hasPkg cfg.home.packages) ["fish" "tmux" "sops"]))
    (ck "the age utilities sit beside the sops wrappers, so age-keygen and `sops edit` work from a shell"
      (lib.all (s.hasPkg cfg.home.packages) ["age"]))
    (ck "hm-nixgl installs its wrappers"
      ((cfg.lib.nixGL ? wrappers) && (lib.attrNames cfg.lib.nixGL.wrappers == ["mesa" "mesaPrime" "nvidia" "nvidiaPrime"])))

    # On a non-NixOS host hm-nixgl supplies the nixGL packages itself, so the derivation that
    # lands on PATH must differ from the plain one -- and must land exactly once, because
    # hm-brave relies on programs.chromium installing its finalPackage rather than adding a
    # second copy here.
    (ck "hm-nixgl supplies nixGL packages on this non-NixOS host"
      (!isNull cfg.targets.genericLinux.nixGL.packages))
    (ck "this host uses the default nixGL wrapper" (cfg.targets.genericLinux.nixGL.defaultWrapper == "mesa"))

    # On a non-NixOS host nothing can set kernel.yama.ptrace_scope (features/hm-brave/nixos.nix
    # only exists for NixOS), so activation must tell the user to set it themselves.
    (ck "the standalone host prints a ptrace hint at activation"
      (lib.hasAttr "bravePtraceHint" cfg.home.activation))
    (ck "the hint names the sysctl key and the command to set it"
      (lib.hasInfix "kernel.yama.ptrace_scope" cfg.home.activation.bravePtraceHint.data
        && lib.hasInfix "sudo sysctl kernel.yama.ptrace_scope=1" cfg.home.activation.bravePtraceHint.data))
    (ck "this host installs at least one package from a feature derivation"
      (lib.any (pkg: installed pkg != []) rawPkgs))
    (ck "every package from a feature derivation is wrapped and on PATH exactly once"
      (lib.all wrappedOnce rawPkgs))

    # The two features no real host enables yet: dcal lands on PATH unwrapped (it is a plain
    # binary, not a GPU app), ghostty lands wrapped exactly once.
    (ck "a fixture host asking for hm-dcal gets dcal on PATH exactly once"
      ((lib.length (fxInstalled dcal)) == 1 && (lib.head (fxInstalled dcal)).outPath == dcal.outPath))
    (ck "its desktop entry points at that binary"
      (lib.hasPrefix "${dcal.outPath}/bin/dcal" fx.xdg.desktopEntries."com.danklinux.dankcalendar".exec))
    (ck "a fixture host asking for hm-ghostty gets the wrapped package exactly once"
      ((lib.length (fxInstalled raw.ghostty))
        == 1
        && (lib.head (fxInstalled raw.ghostty)).outPath != raw.ghostty.outPath))

    # The pinned fork build is what the program module installs. The upstream wrapper inherits
    # pname/version from the unwrapped package, so `version` reads back as the pinned commit.
    # Only `version` is forced: forcing outPath would fetch the crate set behind Cargo.lock.
    (ck "programs.yazi installs the pinned fork build"
      (cfg.programs.yazi.enable
        && (cfg.programs.yazi.package.version == (builtins.fromJSON (builtins.readFile ../features/hm-yazi/metadata.json)).version)))

    # hm-base ships packages, not program flags; that contract shows up in the
    # host's own package list, which is what the profile actually promises.
    (ck "hm-base's CLI packages land in home.packages"
      (lib.all (s.hasPkg cfg.home.packages) ["fish" "starship" "ripgrep" "atuin"]))

    # Its must-throw side lives in tests/loader.nix, since this suite forces a real host
    # config and so stays outside the nix-unit process.
  ];
in
  suite "home" checks
