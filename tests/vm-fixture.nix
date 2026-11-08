# Green suite: the VM e2e fixture host (tests/vm-fixture/), asserted against the tree the installer
# actually lays down. Eval only — nothing here builds a system or boots a VM (see TEST_DESIGN.md).
#
# The point is drift: terraform.sh carries the subvolume list as a shell string, and the fixture
# carries its mounts as a Nix attrset. If those two disagree, deploy installs a system whose boot
# mounts hide the store, and the host never comes up. Comparing them here is the cheap half of the
# proof; booting the fixture is the expensive half (tests/vm-e2e.bats).
let
  s = import ./support.nix;
  inherit (s) lib ck suite;

  np = s.flake.inputs.nixpkgs;
  # Evaluated through eval-config.nix rather than the flake's host builder: the fixture is not a
  # flake host, and this is the same entry point tests/vm-lib.bash builds the guest through.
  cfg =
    (import (np + /nixos/lib/eval-config.nix) {
      inherit (np) lib;
      system = "x86_64-linux";
      modules = [./vm-fixture/nixos.nix];
    }).config;

  recipe = builtins.fromJSON (builtins.readFile ./vm-fixture/terraform.json);
  rootUuid = (lib.findFirst (p: p.mount == "/") null recipe.partitions).uuid;
  rootDevice = "/dev/disk/by-uuid/${rootUuid}";

  # terraform.sh's subvolume_tree, parsed out of the script that creates it, so the expectation is
  # the installer's own list rather than a copy of it kept in this file.
  tree = let
    line =
      lib.findFirst
      (l: lib.hasPrefix "subvolume_tree=" l)
      null
      (lib.splitString "\n" (builtins.readFile ../terraform.sh));
    value = builtins.head (builtins.match "subvolume_tree=\"([^\"]*)\"" line);
    entries = lib.splitString " " value;
  in
    lib.foldl
    (
      acc: entry: let
        # <subvolume>:<mount path>, so the mount path is the key.
        pair = builtins.match "^([^:]+):(.+)$" entry;
      in
        acc
        // {
          ${lib.head (lib.tail pair)} = lib.head pair;
        }
    )
    {}
    entries;

  # fsLib consumes `subvol` as sugar into the mount's options, and fileSystems keeps options as a
  # list, so the subvolume is read back out of that list.
  # The subvolume mounts are exactly the ones whose options carry a subvol=, so a mount of the
  # plain root cannot slip in and pass as one of the tree.
  subvolOf = m: lib.removePrefix "subvol=" (lib.findFirst (o: lib.hasPrefix "subvol=" o) "" (m.options or []));
  subvolMounts = lib.filterAttrs (_: m: subvolOf m != "") cfg.fileSystems;

  namesRoot = m: m.device == rootDevice && m.fsType == "btrfs";
in
  suite "vm-fixture" [
    (ck "its recipe owns the disk and names both filesystems by uuid"
      (recipe.owns && lib.all (p: p.uuid or "" != "") recipe.partitions))

    (ck "the fixture mounts exactly the subvolume tree terraform.sh creates"
      (lib.attrNames subvolMounts
        == lib.attrNames tree
        && lib.all (w: subvolOf subvolMounts.${w} == tree.${w}) (lib.attrNames tree)
        && lib.all namesRoot (lib.attrValues subvolMounts)))

    # Two halves of the same equality, spelled out so a failure names which half broke.
    (ck "no mount the tree does not name is a subvolume mount"
      (lib.attrNames subvolMounts == lib.attrNames tree))

    # A mount of @nix that is not neededForBoot is fine; @log not mounting early is not — boot
    # logging runs before switch_root.
    (ck "only /var/log mounts for boot"
      (cfg.fileSystems."/var/log".neededForBoot
        && lib.all
        (w: w == "/var/log" || !subvolMounts.${w}.neededForBoot)
        (lib.attrNames subvolMounts)))

    # The recipe's own partitions still come from the recipe: /boot is the ESP, not a subvolume.
    (ck "the ESP comes from the recipe and is not a subvolume"
      (cfg.fileSystems."/boot".fsType == "vfat" && !lib.hasAttr "subvol" cfg.fileSystems."/boot"))

    (ck "root and one wheel admin exist, and neither has a build-time password"
      (lib.hasAttr "root" cfg.users.users
        && cfg.users.users.josh.isNormalUser
        && lib.elem "wheel" cfg.users.users.josh.extraGroups
        && cfg.users.users.josh.password == null
        && cfg.users.users.root.password == null))

    # chpasswd and the serial login both go through PAM, and /etc/pam.d only exists for listed
    # services, so a fixture missing them fails with a message that looks like a permissions bug.
    (ck "the PAM services the tier needs are declared"
      (cfg.security.pam.services.login or null
        != null
        && cfg.security.pam.services.chpasswd or null != null))

    (ck "the marker service reaches multi-user.target"
      (cfg.systemd.services.vm-marker.wantedBy
        == ["multi-user.target"]
        && cfg.systemd.services.vm-marker.serviceConfig.Type == "oneshot"))
  ]
