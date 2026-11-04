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

  # The copies of one derivation that reached PATH. Absence is allowed — which GUI features a
  # host enables is the host's business — so the companion check below keeps this from going
  # vacuous on a host with no GUI feature at all.
  installed = pkg: lib.filter (p: (p.pname or p.name) == (pkg.pname or pkg.name)) cfg.home.packages;
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
    (ck "this host installs at least one package from a feature derivation"
      (lib.any (pkg: installed pkg != []) rawPkgs))
    (ck "every package from a feature derivation is wrapped and on PATH exactly once"
      (lib.all wrappedOnce rawPkgs))

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

    # Must-throw guards for this suite live in tests/red/home-config-is-not-nixos.nix.
  ];
in
  suite "home" checks
