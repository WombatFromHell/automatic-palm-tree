{
  config,
  lib,
  inputs,
  ...
}:
# ── nixos-disko: declarative disk layout ──
# The layout itself is a host module (`disko.devices`), never a host record attribute
# (ADR-5c64), so this module brings disko in and enforces the one thing that cannot be undone.
#
# disko's module writes `fileSystems` whenever `enableConfig` is on, even with no devices
# declared, which would clobber the fsLib-built mounts of a host that opted in without a layout.
# `imports` cannot depend on `config` (the module system recurses), so the gate is `enableConfig`
# rather than a conditional import.
{
  imports = [inputs.disko.nixosModules.disko];

  config.disko.enableConfig = lib.mkIf (config.disko.devices.disk == {}) false;

  # A `gpt` layout runs `sgdisk --clear` when `blkid` reports nothing for the disk, and for each
  # partition it nominates it falls back to rewriting that index's GUID, name and typecode — on a
  # disk shared with Windows that is the boot metadata Windows lives on.
  config.assertions = [
    {
      assertion =
        lib.all
        (d: d.content.type != "gpt" || config.flakeHost.ownsWholeDisk)
        (builtins.attrValues config.disko.devices.disk);
      message =
        "${config.flakeHost.name}: a disk with content.type = \"gpt\" partitions the whole drive, "
        + "so it can rewrite partitions this host does not own. Set flakeHost.ownsWholeDisk = true "
        + "only for a host whose drive is NixOS's alone.";
    }
  ];
}
