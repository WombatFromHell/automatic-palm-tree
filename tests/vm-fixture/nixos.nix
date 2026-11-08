# The host the VM e2e tier installs and then boots. Deliberately nothing a real host carries: no
# profiles, no services, no home config. A minimal closure is what keeps `nixos-install` inside the
# guest's memory cap, and the tier proves the plumbing (partition table, subvolume tree, store copy,
# activation, keys, passwords, boot), not the desktop.
{
  lib,
  pkgs,
  ...
}: let
  # The same mount helpers the real hosts use, so the fixture's mounts are derived from its recipe
  # exactly the way hosts/methyl-test's are (ADR-62773e12d275). `nixpkgs` here is the package set's
  # own source path, which is what lib/filesystems.nix needs to reach nixos/lib/utils.nix.
  fsLib = import ../../lib/filesystems.nix {
    inherit lib;
    nixpkgs = pkgs.outPath;
  };
  recipe = builtins.fromJSON (builtins.readFile ./terraform.json);
  mounts = fsLib.mountsFromRecipe recipe;
  subvols = import ./subvols.nix;
in {
  networking.hostName = "vm-fixture";
  system.stateVersion = "25.11";

  # The installed system boots from the ESP terraform.sh formats on the same drive as the root, so
  # systemd-boot writes into /boot and nothing touches EFI variables (the VM has none).
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.systemd-boot.enable = true;

  fileSystems =
    mounts
    // fsLib.mkMounts mounts."/" (lib.mapAttrs (where: subvol: {
        inherit subvol;
        # Boot logging reads /var/log before the root filesystem switch, so it mounts early.
        neededForBoot = where == "/var/log";
      })
      subvols);

  # The accounts install.sh's postdeploy sets passwords for: root, and one wheel admin. Neither has
  # a password at build time — the point of the tier is that chpasswd gives them one.
  users.users = {
    root = {};
    josh = {
      isNormalUser = true;
      extraGroups = ["wheel"];
    };
  };

  # /etc/pam.d is generated only for the services listed here, and both paths the tier exercises go
  # through PAM: chpasswd (postdeploy) and the serial login. Without them each fails with
  # "pam_chauthtok() failed: Permission denied", which reads like a permissions bug.
  security.pam.services = {
    login = {};
    chpasswd = {};
  };

  # Reaching multi-user.target is the boot proof; the marker line lands in the serial log the host
  # keeps, so a silent boot still fails the assertion.
  systemd.services.vm-marker = {
    description = "flakeroot VM e2e marker";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''echo "VM MARKER OK: installed system reached multi-user.target"'';
  };
}
