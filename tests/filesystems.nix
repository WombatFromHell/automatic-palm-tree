# Green suite: lib/filesystems.nix. Pure — only the lib is evaluated, no host config forced.
let
  s = import ./support.nix;
  inherit (s) lib;
  fs = import ../lib/filesystems.nix {inherit lib;};

  mk = defaults: entry: (fs.mkMounts defaults {"/m" = entry;})."/m";
  unit = defaults: units: fs.mkUnitMounts defaults units;
  mount1 = u: builtins.head u.mounts;
  auto1 = u: builtins.head u.automounts;
  has = k: m: builtins.hasAttr k m;
in
  s.suite "filesystems" [
    # mkMounts -> `fileSystems` attrsets
    (s.ck "entry keys win over defaults"
      (mk {
          device = "/dev/a";
          fsType = "ext4";
        } {
          device = "/dev/b";
          fsType = "vfat";
        }
        == {
          device = "/dev/b";
          fsType = "vfat";
        }))

    # `options` is NixOS semantics: an entry replaces the defaults, it does not extend them.
    (s.ck "entry options replace defaults"
      (mk {options = ["noatime"];} {options = ["nodev"];} == {options = ["nodev"];}))
    (s.ck "defaults options survive an empty entry"
      (mk {options = ["noatime"];} {} == {options = ["noatime"];}))
    (s.ck "subvol is appended last"
      (mk {options = ["noatime"];} {subvol = "@";} == {options = ["noatime" "subvol=@"];}))
    (s.ck "subvol null adds nothing"
      (mk {options = ["noatime"];} {subvol = null;} == {options = ["noatime"];}))
    (s.ck "empty option list is dropped so NixOS defaults apply"
      (mk {} {} == {}))

    # mkUnitMounts -> { mounts, automounts }, both LISTS
    (s.ck "string shorthand sets what and keeps defaults"
      (mount1 (unit {type = "btrfs";} {"/mnt/x" = "/dev/x";})
        == {
          what = "/dev/x";
          type = "btrfs";
          where = "/mnt/x";
          description = "Mount for /mnt/x";
          options = "";
        }))

    (s.ck "automount defaults to false"
      (let
        u = unit {} {"/mnt/x" = {};};
      in
        u.automounts == [] && ! has "requires" (mount1 u) && ! has "after" (mount1 u)))

    (s.ck "automount adds <unit>.automount to the mount's requires and after"
      (let
        u = unit {} {
          "/mnt/x" = {
            what = "/dev/x";
            automount = true;
          };
        };
        m = mount1 u;
      in
        m.requires == ["mnt-x.automount"] && m.after == ["mnt-x.automount"]))

    # The cycle guard: the automount is a lazy trigger, never a dependent.
    (s.ck "automount is whitelisted: no deps, options, what or type"
      (builtins.attrNames
        (auto1 (unit {} {
          "/mnt/x" = {
            what = "/dev/x";
            type = "btrfs";
            automount = true;
            requires = ["network-online.target"];
            after = ["network-online.target"];
            options = ["rw"];
          };
        }))
        == ["description" "wantedBy" "where"]))

    (s.ck "unitConfig and mountConfig pass by value; mountConfig stays on the mount"
      (let
        u = unit {} {
          "/mnt/x" = {
            what = "/dev/x";
            automount = true;
            mountConfig = {TimeoutSec = 5;};
            unitConfig = {ConditionPathExists = "/dev/x";};
          };
        };
        m = mount1 u;
        a = auto1 u;
      in
        m.mountConfig
        == {TimeoutSec = 5;}
        && m.unitConfig == {ConditionPathExists = "/dev/x";}
        && a.unitConfig == {ConditionPathExists = "/dev/x";}
        && ! has "mountConfig" a))

    (s.ck "options become a comma string"
      (let u = unit {} {"/mnt/x" = {options = ["noatime" "nodev"];};}; in (mount1 u).options == "noatime,nodev"))
    (s.ck "empty options become an empty string"
      (let u = unit {} {"/mnt/x" = {};}; in (mount1 u).options == ""))

    (s.ck "skipIfMissing sets ConditionPathExists on both units and drops the sugar key"
      (let
        u = unit {} {
          "/mnt/x" = {
            what = "/dev/x";
            automount = true;
            skipIfMissing = true;
          };
        };
        m = mount1 u;
        a = auto1 u;
      in
        m.unitConfig.ConditionPathExists
        == "/dev/x"
        && a.unitConfig.ConditionPathExists == "/dev/x"
        && ! has "skipIfMissing" m
        && ! has "skipIfMissing" a))

    (s.ck "wantedBy and descriptions default, entries win"
      (let
        u = unit {} {
          "/mnt/x" = {
            what = "/dev/x";
            automount = true;
            wantedBy = ["graphical-session.target"];
            description = "Data disk";
          };
        };
        m = mount1 u;
        a = auto1 u;
      in
        a.wantedBy
        == ["graphical-session.target"]
        && m.description == "Data disk"
        && a.description == "Data disk"
        && (auto1 (unit {} {"/mnt/x" = {automount = true;};})).wantedBy == ["multi-user.target"]))

    (s.ck "joinUnitMounts merges groups in order and yields {} on no groups"
      (let
        a = unit {} {
          "/a" = {
            what = "/dev/a";
            automount = true;
          };
        };
        b = unit {} {
          "/b" = {
            what = "/dev/b";
            automount = true;
          };
        };
        j = fs.joinUnitMounts [a b];
      in
        fs.joinUnitMounts []
        == {}
        && map (m: m.where) j.mounts == ["/a" "/b"]
        && map (m: m.where) j.automounts == ["/a" "/b"]))
  ]
