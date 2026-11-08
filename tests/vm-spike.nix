{
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd.availableKernelModules = ["virtio_blk" "virtio_pci" "virtio_net" "9p" "btrfs"];
    kernelModules = ["btrfs"];
    # tmpfs for /tmp would charge the guest's RAM twice over; the run dir is on disk.
    tmp.useTmpfs = false;
  };

  # The config is evaluated through eval-config.nix rather than the flake's toortek system, so it
  # does not inherit toortek's allowUnfreeProvider — terraform (BSL-1.1) would refuse to evaluate.
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "25.11";
  # Fixed name so the runner can call bin/run-vm-spike-vm instead of globbing a generated one.
  system.name = "vm-spike";

  # The accounts the installer's postdeploy creates, so the spike proves the password path the e2e
  # tier depends on. Neither has a password at build time: root's only exists once chpasswd has run
  # inside the guest, which is what the serial login then proves.
  users.users = {
    root = {};
    # NixOS requires a normal/system-user flag and a group; without them the config fails to
    # evaluate, so the account postdeploy sets a password for would never exist.
    josh = {
      isNormalUser = true;
      group = "josh";
    };
  };
  users.groups.josh = {};

  # /etc/pam.d is generated only for the services listed here, and both of them go through PAM:
  # chpasswd (what postdeploy runs) and the serial login. Without them each fails with
  # "pam_chauthtok() failed: Permission denied", which reads like a permissions bug but is a
  # missing config file.
  security.pam.services = {
    login = {};
    chpasswd = {};
  };

  # Everything the real stages need, present in the guest before any of them runs, so a missing
  # tool fails the assertion instead of becoming an on-demand download inside the VM.
  environment.systemPackages = with pkgs; [
    nixos-install-tools # nixos-install, nixos-enter
    kubernetes-helm
    terraform
    bats
    jq
  ];

  # Values the deploy stage reads, set in the guest config so the tier needs no env plumbing.
  environment.variables = {
    TF_VAR_cloud_token = "tok-9f3a71c2e5d84b6a";
    TF_VAR_cloud_api_url = "https://toortest.example.invalid/v1";
    TF_VAR_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleFixtureKeyForVmTest 2026-07-28";
    FLAKEROOT_NAMESPACE = "flakeroot-ci";
  };

  virtualisation = {
    # Serial console only: the host captures stdout as the run log.
    graphics = false;
    cores = 1;
    memorySize = 1024;

    # diskImage = null makes the root a tmpfs, so guest state dies with the VM and there is no
    # persisted image to inherit from a previous run.
    diskImage = null;

    # The closure is packed by the *host* into an erofs image in $TMPDIR (disk, not RAM) and
    # mounted read-only at /nix/.ro-store; the writable store is the overlay on top.
    useNixStoreImage = true;
    writableStore = true;
    additionalPaths = [./vm-spike.sh];

    # Loud refusal instead of a silent TCG fallback when /dev/kvm is inaccessible.
    qemu.forceAccel = true;

    # Direct boot: no bootloader, so make-disk-image is never built.
    directBoot.enable = true;

    # The blank drive the deploy stage will format and install onto.
    emptyDiskImages = [4096];

    sharedDirectories.e2e = {
      # Inside the script the module generates this is shell text, so the bare $TMPDIR is the
      # per-run dir the runner exports — nothing else needs an override knob.
      source = "$TMPDIR/xchg";
      target = "/mnt/shared";
      securityModel = "none";
    };

    # Secrets do NOT go through systemd credentials here, and that is a measured limitation, not a
    # shortcut: this guest kernel exposes no /sys/firmware/fw_cfg, and qemu's SMBIOS type-11 string
    # arrives empty, so neither mechanism delivers anything. The 9p share above carries the password
    # file, which still keeps the values out of argv, the kernel command line and the serial log.
  };

  systemd.services.vm-spike = {
    description = "flakeroot VM spike";
    # RequiresMountsFor is deliberately absent: /mnt/shared is mounted by the initrd, so no systemd
    # mount unit exists for it after switch_root, and a dependency on one never starts the service.
    # A systemd unit gets its PATH from `Path=`, not from the system path, so the tools step 6
    # asserts on have to be listed here as well as in environment.systemPackages.
    path = [pkgs.bash pkgs.util-linux pkgs.nix pkgs.shadow pkgs.nixos-install-tools];
    # Without this the unit is built but never enabled, so the guest boots and nothing runs.
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      # Marker lines have to reach the serial console, which is what the host logs.
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = builtins.readFile ./vm-spike.sh;
  };
}
