# Zram suite: the effect of the nixos-zram feature, on a fixture host. Nothing is built.
#
# No real host enables nixos-zram (hosts/methyl-base/base.nix keeps it commented out), so this
# host record is built through the same builder the flake uses, and what is asserted is the
# unit and the generator config it reads -- not the enable flag.
let
  s = import ./support.nix;
  inherit (s) ck suite;

  host =
    (s.fixtureHost true ["nixos-zram"] {})
    // {
      name = "zramhost";
      homeModules.josh = [];
    };

  cfg = (s.builders.buildNixosConfigurations {zramhost = host;}).zramhost.config;

  # systemd-zram-generator ships as a template unit; NixOS only installs the package and
  # writes the settings file the unit reads at start.
  unit = cfg.systemd.services."systemd-zram-setup@" or null;
in
  suite "zram" [
    (ck "the host gets the zram setup unit" (!isNull unit))
    (ck "the template unit comes from the generator package, not a hand-written swap command"
      (s.hasPkg cfg.systemd.packages "zram-generator"))
    (ck "the generator config the unit reads is installed"
      (builtins.hasAttr "systemd/zram-generator.conf" cfg.environment.etc))
    (ck "our own settings are the ones that ship, not NixOS defaults"
      (cfg.services.zram-generator.settings.zram0.compression-algorithm == "zstd"))
  ]
