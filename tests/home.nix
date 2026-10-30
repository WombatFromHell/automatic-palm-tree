# Home suite: the standalone (non-NixOS) host, evaluated through the flake's own
# outputs. No build. ~3s.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;

  hm = s.flake.outputs.homeConfigurations."josh@methyl-bazzite";
  cfg = hm.config;

  homePkg = name: s.hasPkg cfg.home.packages name;

  # The standalone host is the one side where nixGL has to wrap: compare the package Home
  # Manager installs against the plain derivation _package.nix produces, outPath only.
  once = name:
    lib.length (lib.filter (p: (p.pname or p.name) == name) cfg.home.packages) == 1;
  rawBrave = s.pkgs.unstable.callPackage ../features/hm-brave/_package.nix {};
  rawZed = (s.pkgs.callPackage ../features/hm-zed/_package.nix {}).noFHS;

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
    (ck "home features reach the configuration"
      (lib.all (f: builtins.hasAttr f cfg.features) ["brave-browser" "tmux-git" "zed-editor"]))
    (ck "host-authored home modules reach the configuration"
      (lib.all homePkg ["cachix" "yt-dlp" "herdr" "trash-cli"]))
    (ck "profile features reach the configuration" (lib.all homePkg ["fish" "tmux" "agenix"]))
    (ck "hm-nixgl installs its wrappers"
      ((cfg.lib.nixGL ? wrappers) && (lib.attrNames cfg.lib.nixGL.wrappers == ["mesa" "mesaPrime" "nvidia" "nvidiaPrime"])))

    # hm-nixgl supplies packages because this host is not NixOS; the GUI derivations it wraps
    # must end up as a different derivation than the plain one, and the program module still
    # installs exactly one copy of each.
    (ck "hm-nixgl supplies nixGL packages on this non-NixOS host"
      (!isNull cfg.targets.genericLinux.nixGL.packages))
    (ck "this host uses the default nixGL wrapper" (cfg.targets.genericLinux.nixGL.defaultWrapper == "mesa"))
    (ck "the GUI derivations are wrapped for this non-NixOS host"
      (cfg.programs.chromium.finalPackage.outPath
        != rawBrave.outPath
        && cfg.programs.zed-editor.package.outPath != rawZed.outPath))
    (ck "each GUI package is on PATH exactly once"
      (once "brave-bin" && once "zed-editor-bin"))

    # hm-base ships packages, not program flags; that contract shows up in the
    # host's own package list, which is what the profile actually promises.
    (ck "hm-base's CLI packages land in home.packages"
      (lib.all homePkg ["fish" "starship" "ripgrep" "atuin"]))

    # Must-throw guards for this suite live in tests/red/home-config-is-not-nixos.nix.
  ];
in
  suite "home" checks
