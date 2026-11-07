# nix-unit attributes for the nixos-oom feature, on a fixture host. Nothing is built.
#
# What is asserted is where the limits land, not that oomd is on: systemd-oomd acts only on
# cgroups it is told to monitor, and a limit written on a unit nobody monitors is dead config.
# Every value here is a percentage, so the same defaults hold on a 32GB host and on a small VM.
let
  s = import ./support.nix;

  base = s.fixtureHost true ["nixos-oom"] {};
  cfgOf = host: (s.builders.buildNixosConfigurations {${host.name} = host;}).${host.name}.config;

  cfg = cfgOf base;
  # A host opting out of the ceiling, and one opting out of the swap rule, both keep the rest.
  noCeiling = cfgOf (base // {nixosModules = [{features.oomd.memoryMax = null;}];});
  noSwapLimit = cfgOf (base // {nixosModules = [{features.oomd.swapUsedLimit = null;}];});

  root = cfg.systemd.slices."-".sliceConfig;
  user = cfg.systemd.slices."user".sliceConfig;
in {
  # ── the swap rule is live: oomd's SwapUsedLimit only acts on cgroup that declare it ──
  testSwapMonitoringOnRootSlice = {
    expr = root.ManagedOOMSwap;
    expected = "kill";
  };
  testSwapMonitoringOnUserSlice = {
    expr = user.ManagedOOMSwap;
    expected = "kill";
  };
  testSwapUsedLimitShipsInTheConf = {
    expr = cfg.systemd.oomd.settings.OOM.SwapUsedLimit;
    expected = "75%";
  };
  # Turning the swap rule off must not take the pressure duration with it.
  testPressureDurationSurvivesNoSwapLimit = {
    expr = noSwapLimit.systemd.oomd.settings.OOM.DefaultMemoryPressureDurationSec;
    expected = "15s";
  };

  # ── the pressure limit lands on the slice, where upstream's mkDefault 80% would otherwise win ──
  testPressureLimitOnUserSlice = {
    expr = user.ManagedOOMMemoryPressureLimit;
    expected = "60%";
  };
  testPressureDurationOnUserSlice = {
    expr = user.ManagedOOMMemoryPressureDurationSec;
    expected = "15s";
  };
  # The session is the thing to act inside, so it must not be de-prioritised.
  testSessionIsNotDeprioritised = {
    expr = cfg.systemd.services."user@".serviceConfig ? ManagedOOMPreference;
    expected = false;
  };
  testSessionStillMonitored = {
    expr = cfg.systemd.services."user@".serviceConfig.ManagedOOMMemoryPressure;
    expected = "kill";
  };
  testDisplayManagerStaysOmitted = {
    expr = cfg.systemd.services.display-manager.serviceConfig.ManagedOOMPreference;
    expected = "omit";
  };

  # ── the ceiling: nothing in oomd bounds RAM, MemoryMax= on -.slice does ──
  testThrottleBeginsAboveTheStrataBaseline = {
    expr = root.MemoryHigh;
    expected = "93%";
  };
  testMemoryCeilingIs97Percent = {
    expr = root.MemoryMax;
    expected = "97%";
  };
  testCeilingCanBeOptedOut = {
    expr = noCeiling.systemd.slices."-".sliceConfig ? MemoryMax;
    expected = false;
  };

  # ── the notify daemon is opt-in, and stays a user unit ──
  testNotifyUnitAbsentByDefault = {
    expr = cfg.systemd.user.services ? oomd-notify;
    expected = false;
  };
  testNotifyUnitFromFeatureValue = let
    notify = cfgOf (base // {nixosModules = [{features.oomd.notify = true;}];});
  in {
    expr = notify.systemd.user.services ? oomd-notify;
    expected = true;
  };
}
