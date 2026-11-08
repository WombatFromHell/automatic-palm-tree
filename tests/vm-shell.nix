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

  # Evaluated through eval-config.nix rather than the flake's toortek system, so this does not
  # inherit toortek's allowUnfreeProvider — terraform (BSL-1.1) would refuse to evaluate.
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "25.11";
  # Fixed name so the runner calls bin/run-vm-shell-vm instead of globbing a generated one.
  system.name = "vm-shell";

  # A root shell on the serial console, no password. The guest is scratch: its root is tmpfs, it has
  # no secrets of its own, and the console is the interface a person drives (ADR-953e34c78819's
  # scratch-machine rule — nothing durable lives here).
  services.getty.autologinUser = "root";

  # Everything the real stages run, present before anything is asked of them, so a missing tool
  # fails the probe instead of becoming an on-demand download inside the VM.
  environment.systemPackages = with pkgs; [
    nix
    nixos-install-tools # nixos-install, nixos-enter
    terraform
    jq
    dosfstools # mkfs.vfat, which terraform.sh formats the ESP with
    btrfs-progs # mkfs.btrfs and the subvolume commands
  ];

  # The guest names its own target drive: its root is tmpfs, so no mount source and no formatted
  # partition can name one. install.sh's INSTALL_DRIVE guard reads this (PLAN-vm-interactive.md D2).
  environment.variables.INSTALL_DRIVE = "/dev/vdb";

  virtualisation = {
    # Serial console only: the host captures stdio as the console and the run log.
    graphics = false;
    cores = 1;
    memorySize = 1024;

    # diskImage = null makes the root a tmpfs, so guest state dies with the VM and there is no
    # image to inherit from a previous run.
    diskImage = null;

    # The closure is packed by the *host* into an erofs image in the run dir (disk, not RAM) and
    # mounted read-only at /nix/.ro-store; the writable store is the overlay on top.
    useNixStoreImage = true;
    writableStore = true;

    # Loud refusal instead of a silent TCG fallback when /dev/kvm is inaccessible.
    qemu.forceAccel = true;

    # Direct boot: no bootloader, so make-disk-image is never built.
    directBoot.enable = true;

    # The blank drive install.sh formats and installs onto.
    emptyDiskImages = [4096];

    sharedDirectories.repo = {
      # Inside the script the module generates this is shell text, so the bare $TMPDIR is the
      # per-run dir the runner exports — no extra override knob.
      source = "$TMPDIR/xchg";
      target = "/mnt/repo";
      securityModel = "none";
    };

    # Secrets ride the same 9p share: the repo copy carries tests/vm-spike-secrets.env, and the
    # installer reads it as INSTALL_PASSWORDS. systemd credentials are not used — this guest kernel
    # exposes no /sys/firmware/fw_cfg and qemu's SMBIOS type-11 string arrives empty, so neither
    # mechanism delivers anything (measured in the spike, not assumed).
  };
}
