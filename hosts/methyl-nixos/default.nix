{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-ws"]
  ++ [
    {
      # The VM's drive is NixOS's alone, which is the only thing that lets a gpt table partition it
      # (ADR-887173ed9424). methyl and propyl share theirs with Windows. The layout itself is the
      # recipe in ./terraform.json, reproduced by terraform.sh (ADR-b77ec913151f).
      ownsWholeDisk = true;
      features = [
        "nixos-cachyos"
        "nixos-btrfs"
        "nixos-qemu"
        "nixos-niri"
        "nixos-dms"
      ];
    }
  ]
)
