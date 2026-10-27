# Home suite: the standalone (non-NixOS) host, evaluated through the flake's own
# outputs. No build. ~3s.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;

  hm = s.flake.outputs.homeConfigurations."josh@methyl-bazzite";
  cfg = hm.config;

  homePkg = name: s.hasPkg cfg.home.packages name;

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
    (ck "the standalone host produces no warnings" (cfg.warnings == []))

    # hm-base ships packages, not program flags; that contract shows up in the
    # host's own package list, which is what the profile actually promises.
    (ck "hm-base's CLI packages land in home.packages"
      (lib.all homePkg ["fish" "starship" "ripgrep" "atuin"]))

    # Must-throw guards for this suite live in tests/red/home-config-is-not-nixos.nix.
  ];
in
  suite "home" checks
