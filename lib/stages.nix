# ── deployment stages ──
# Stage 1 = the light host record: boot-critical features only (`bootFeatures`) and no Home
# Manager users, so a low-memory machine can build + activate a system that gives it swap
# before building the full config. Stage 2 = the host record unchanged.
#
# The gate is runtime memory (`bootstrap.sh`), not a build-time marker: stage 1 changes the
# answer by adding swap, so re-deriving it on the next run is exactly what we want.
_: let
  # Build throttling for stage 1, so stage 2 (the full config) has room to build on the
  # machine it is being built on. `nix.settings` is what the nix daemon reads, so this is the
  # authoritative lever; CLI flags/env only cover daemon-less builds (bootstrap.sh still sets
  # NIX_CONFIG for those). `boot.tmp.useTmpfs` is left alone — it is already false upstream,
  # so /tmp costs no RAM here.
  # systemd-oomd is off during stage 1: its `ManagedOOMMemoryPressure = "kill"` on user@
  # service units would kill the very build that is trying to fix the machine. mkForce because
  # nixos-oom assigns `systemd.oomd.enable = cfg.features.oomd.enable` plainly.
  bootTuningModule = {lib, ...}: {
    nix.settings.max-jobs = lib.mkDefault 1;
    nix.settings.cores = lib.mkDefault 1;
    systemd.oomd.enable = lib.mkForce false;
  };
in {
  inherit bootTuningModule;

  mkBootHost = host:
    host
    // {
      features = host.bootFeatures;
      hmUsernames = [];
      nixosModules = host.nixosModules ++ [bootTuningModule];
    };
}
