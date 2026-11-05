# nix-unit attributes for the nixos-zram feature, on a fixture host. Nothing is built.
#
# No real host enables nixos-zram (hosts/methyl-base/base.nix keeps it commented out), so this
# host record is built through the same builder the flake uses, and what is asserted is the unit
# and the generator config it reads -- not the enable flag.
let
  s = import ./support.nix;

  host =
    (s.fixtureHost true ["nixos-zram"] {})
    // {
      name = "zramhost";
      homeModules.josh = [];
    };

  cfg = (s.builders.buildNixosConfigurations {zramhost = host;}).zramhost.config;

  # systemd-zram-generator ships as a template unit; NixOS only installs the package and writes
  # the settings file the unit reads at start. The unit's presence is the first attribute below.
in
  {
    testHostGetsTheZramSetupUnit = {
      expr = cfg.systemd.services ? "systemd-zram-setup@";
      expected = true;
    };
    testTemplateUnitComesFromTheGeneratorPackage = {
      expr = s.hasPkg cfg.systemd.packages "zram-generator";
      expected = true;
    };
    testGeneratorConfigIsInstalled = {
      expr = builtins.hasAttr "systemd/zram-generator.conf" cfg.environment.etc;
      expected = true;
    };
    # Our own settings are the ones that ship, not NixOS defaults.
    testZramCompressionAlgorithmIsZstd = {
      expr = cfg.services.zram-generator.settings.zram0.compression-algorithm;
      expected = "zstd";
    };
  }
