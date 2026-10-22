# KaiT2en: T2 Mac support (kernel, out-of-tree modules, bridgeOS services).
#
# House shape — options.features.kait2en.* + `config = lib.mkMerge [ (mkIf ...) ... ]`. Defaults
# assume a MacBookPro16,2 (Ice Lake only, Touch Bar present), so `hardware.kait2en.gpuControl`
# stays off. # ponytail: for MacBookPro16,1 / 16,4 (dGPU) set
# `hardware.kait2en.gpuControl.mode = "hybrid"` and `amdgpuAspm = false`.
#
# Kernel pin: KaiT2en's own module defaults `hardware.kait2en.kernelPackages` to
# `pkgs.linuxPackagesFor` its patched kernel built with the *host* package set, which on our
# chilled nixpkgs gives an uncached 7.2.9. We pin it to KaiT2en's own package set instead —
# their CI pushes that closure to https://nix.channings.me, so the laptop substitutes 7.2.11 +
# the module set instead of compiling it. Upstream sets
# `boot.kernelPackages = mkDefault cfg.kernelPackages` (priority 1000), which beats
# modules/defaults/nixos.nix at 1100.
{
  inputs,
  lib,
  config,
  ...
}: let
  cfg = config.features.kait2en;
  # KaiT2en's locked nixpkgs (rev 02c087f3), not our chilled one: the rev their CI builds and
  # pushes to the cache. Their lib exposes the patched kernel and the modules built against it.
  kait2enPkgs = inputs.kait2en.inputs.nixpkgs.legacyPackages.x86_64-linux;
  kait2enLib = inputs.kait2en.lib.x86_64-linux;
  inherit (kait2enLib) kait2enKernel;
in {
  # The model-agnostic baseline (boot params, cdc_mbim blacklist, redistributable firmware,
  # PipeWire + rtkit). `nixosProfiles.macbookpro16-2` does not exist upstream yet — profiles
  # are listed by hand in its flake.nix — so the baseline is imported and the model knobs are
  # set here. Swap this for that profile once upstream adds it.
  imports = [(inputs.kait2en.outPath + "/nix/profiles/default.nix")];

  options.features.kait2en = {
    enable =
      lib.mkEnableOption "KaiT2en support for a T2 Mac (kernel, modules, services)"
      // {
        default = true;
      };
    model = lib.mkOption {
      type = lib.types.str;
      default = "16_2";
      description = "Model key for services.t2bce-audio-dsp.model (e.g. 16_2, 16_1, 9_1).";
    };
  };

  config = lib.mkMerge [
    # Gate 1: the cache is deployed while `flakeHost.bootstrap` is true, so /etc/nix/nix.conf
    # carries it before the switch that flips bootstrap = false picks up the patched kernel.
    (lib.mkIf cfg.enable {
      nix.settings.extra-substituters = ["https://nix.channings.me"];
      nix.settings.extra-trusted-public-keys = ["garage:JZet/fsItH8cJ6SKLci1+BuMIQGDfZSa/8GxGpKcxss="];
    })
    # Gate 2: the patched kernel and the T2 services only once bootstrap is off.
    (lib.mkIf (cfg.enable && !config.flakeHost.bootstrap) {
      hardware.kait2en = {
        enable = true;
        firmware.enable = true;
        # Generic installer branch (scripts/fedora/install-kernel-args.sh): amdgpu.aspm=1,
        # pcie_aspm=force. 16,1's ASPM-off is a Navi 14 quirk; 16,2 has no AMD GPU.
        amdgpuAspm = true;
        pcieAspm = "force";
        kernelPackages = lib.mkDefault (kait2enPkgs.linuxPackagesFor kait2enKernel);
        # `kernelModulesFor` returns an attrset; the option wants the derivations.
        modulePackages = lib.filter lib.isDerivation (lib.attrValues (kait2enLib.kernelModulesFor kait2enKernel));
      };

      # Group membership through the house namespace (modules/defaults/nixos.nix merges
      # extraGroups into isAdmin users); KaiT2en's service module creates the group itself.
      extraGroups.kait2en = lib.mkIf config.services.t2-touchbar.enable ["kait2en-touchbar"];

      # One graph per model, so `model` is a knob rather than a hard-coded string.
      services = {
        t2-touchbar.enable = true;
        kait2en-suspend.enable = true;
        kait2en-rtc-sync.enable = true;
        t2-services.enable = true;
        t2-ave.enable = true;
        t2-touchid.enable = true;
        t2-fan-control.enable = true;
        t2-smc-control.enable = true;
        t2-power-explorer.enable = true;
        t2-power-tune.enable = true;
        t2-zone-power.enable = true;
        t2-force-click.enable = true;
        t2-journal.enable = true;
        t2bce-audio-dsp = {
          enable = true;
          inherit (cfg) model;
        };
      };
    })
  ];
}
