# Green suite: features/nixos-automounts, asserted on the real host configs.
# Eval only — the generated unit files are not built (see TEST_DESIGN.md).
let
  s = import ./support.nix;
  inherit (s) lib;

  # Hosts come from the records, not from hard-coded names. Hosts without a
  # nixosConfigurations entry (e.g. methyl-bazzite, a Bazzite host) are skipped.
  hosts =
    lib.filter (h: lib.hasAttr h.name s.flake.outputs.nixosConfigurations)
    (lib.attrValues s.hosts.discoveredHosts);
  enabled = h: lib.elem "nixos-automounts" h.features;
  cfg = h: s.flake.outputs.nixosConfigurations.${h.name}.config;
  featureHosts = lib.filter enabled hosts;

  # ponytail: mirrors lib/filesystems.nix `unitName`; export it from the lib if a
  # second suite needs it.
  unitName = where: lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" where);
  cred = "/etc/.smb-credentials";

  mountAt = h: a: lib.findFirst (m: m.where == a.where) null (cfg h).systemd.mounts;
  cifsMounts = h: lib.filter (m: (m.type or null) == "cifs") (cfg h).systemd.mounts;
  # `->` binds tighter than `or`, so every optional-attr test below is parenthesized.
in
  s.suite "mounts" [
    (s.ck "only the hosts enabling the feature have automounts"
      (lib.all (h: enabled h == builtins.length (cfg h).systemd.automounts > 0) hosts
        && featureHosts != []))

    (s.ck "every automount has a mount at the same where"
      (lib.all (h: lib.all (a: mountAt h a != null) (cfg h).systemd.automounts) featureHosts))

    (s.ck "that mount requires and after the automount unit"
      (lib.all (h:
        lib.all (a: let
          m = mountAt h a;
          d = "${unitName a.where}.automount";
        in
          lib.elem d (m.requires or []) && lib.elem d (m.after or []))
        (cfg h).systemd.automounts)
      featureHosts))

    # The boot-cycle guard, on real units: the automount is a lazy trigger.
    (s.ck "automounts carry no requires, after or wants"
      (lib.all (h:
        lib.all (a: (a.requires or []) == [] && (a.after or []) == [] && (a.wants or []) == [])
        (cfg h).systemd.automounts)
      featureHosts))

    (s.ck "automounts are wanted by multi-user.target"
      (lib.all (h: lib.all (a: a.wantedBy == ["multi-user.target"]) (cfg h).systemd.automounts) featureHosts))

    (s.ck "automounts carry no what, type, options or mountConfig"
      (lib.all (h:
        lib.all (a:
          ! builtins.hasAttr "what" a
          && ! builtins.hasAttr "type" a
          && ! builtins.hasAttr "options" a
          && ! builtins.hasAttr "mountConfig" a)
        (cfg h).systemd.automounts)
      featureHosts))

    (s.ck "mounts set TimeoutSec 5 and share their automount's ConditionPathExists"
      (lib.all (h:
        lib.all (a: let
          m = mountAt h a;
        in
          (m.mountConfig.TimeoutSec or null)
          == 5
          && (m.unitConfig.ConditionPathExists or null) == (a.unitConfig.ConditionPathExists or null))
        (cfg h).systemd.automounts)
      featureHosts))

    (s.ck "cifs mounts use the credentials file and condition on it"
      (lib.all (h:
        lib.all (m:
          lib.strings.hasInfix "credentials=${cred}" (m.options or "")
          && (m.unitConfig.ConditionPathExists or null) == cred) (cifsMounts h))
      featureHosts))
  ]
