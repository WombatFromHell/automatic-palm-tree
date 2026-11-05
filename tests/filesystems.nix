# Green suite: lib/filesystems.nix. Pure — only the lib is evaluated, no host config forced.
let
  s = import ./support.nix;
  inherit (s) lib ck suite fs;

  mk = defaults: entry: (fs.mkMounts defaults {"/m" = entry;})."/m";
  # One mount point, both units from one eval. Checks that need a specific path (the escaped
  # unit name and joinUnitMounts) call fs.mkUnitMounts directly, since the name is derived
  # from the path.
  unit = defaults: entry: fs.mkUnitMounts defaults {"/mnt/x" = entry;};
  mount = defaults: entry: builtins.head (unit defaults entry).mounts;
  auto = defaults: entry: builtins.head (unit defaults entry).automounts;
in
  suite "filesystems" [
    # mkMounts -> `fileSystems` attrsets
    (ck "entry keys win over defaults"
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

    # The unit name is what systemd derives from the mount point, so '-' and a
    # space must be escaped, not swapped for a dash: '/mnt/a-b' would otherwise name the
    # unit of '/mnt/a/b' and pair with the wrong automount.
    (ck "unitName escapes a path containing '-' and a space"
      ((fs.unitName "/mnt/a-b")
        == "mnt-a\\x2db"
        && (fs.unitName "/mnt/a b") == "mnt-a\\x20b"
        && (fs.unitName "/mnt/a/b") == "mnt-a-b"))
    # The pairing the escaping exists for: the mount names the automount systemd will create.
    (ck "an automount at a path containing '-' pairs with the escaped unit"
      (let
        u = fs.mkUnitMounts {} {
          "/mnt/a-b" = {
            what = "/dev/a";
            automount = true;
          };
        };
        d = "mnt-a\\x2db.automount";
      in
        lib.elem d (builtins.head u.mounts).requires
        && lib.elem d (builtins.head u.mounts).after
        && (builtins.head u.automounts).where == "/mnt/a-b"))

    # `options` is NixOS semantics: an entry replaces the defaults, it does not extend them.
    (ck "entry options replace defaults"
      (mk {options = ["noatime"];} {options = ["nodev"];} == {options = ["nodev"];}))
    (ck "defaults options survive an empty entry"
      (mk {options = ["noatime"];} {} == {options = ["noatime"];}))
    (ck "subvol is appended last"
      (mk {options = ["noatime"];} {subvol = "@";} == {options = ["noatime" "subvol=@"];}))
    (ck "subvol null adds nothing"
      (mk {options = ["noatime"];} {subvol = null;} == {options = ["noatime"];}))
    (ck "empty option list is dropped so NixOS defaults apply"
      (mk {} {} == {}))

    # mkUnitMounts -> { mounts, automounts }, both LISTS
    (ck "string shorthand sets what and keeps defaults"
      ((mount {type = "btrfs";} "/dev/x")
        == {
          what = "/dev/x";
          type = "btrfs";
          where = "/mnt/x";
          description = "Mount for /mnt/x";
          options = "";
        }))

    (ck "automount defaults to false"
      (let
        u = unit {} {};
        m = builtins.head u.mounts;
      in
        u.automounts
        == []
        && ! (builtins.hasAttr "requires" m)
        && ! (builtins.hasAttr "after" m)))

    (ck "automount adds <unit>.automount to the mount's requires and after"
      (let
        m = mount {} {
          what = "/dev/x";
          automount = true;
        };
      in
        m.requires == ["mnt-x.automount"] && m.after == ["mnt-x.automount"]))

    # The cycle guard: the automount is a lazy trigger, never a dependent.
    (ck "automount is whitelisted: no deps, options, what or type"
      (builtins.attrNames
        (auto {} {
          what = "/dev/x";
          type = "btrfs";
          automount = true;
          requires = ["network-online.target"];
          after = ["network-online.target"];
          options = ["rw"];
        })
        == ["description" "wantedBy" "where"]))

    (ck "unitConfig and mountConfig pass by value; mountConfig stays on the mount"
      (let
        u = unit {} {
          what = "/dev/x";
          automount = true;
          mountConfig = {TimeoutSec = 5;};
          unitConfig = {ConditionPathExists = "/dev/x";};
        };
        m = builtins.head u.mounts;
        a = builtins.head u.automounts;
      in
        m.mountConfig
        == {TimeoutSec = 5;}
        && m.unitConfig == {ConditionPathExists = "/dev/x";}
        && a.unitConfig == {ConditionPathExists = "/dev/x";}
        && ! (builtins.hasAttr "mountConfig" a)))

    (ck "options become a comma string"
      ((mount {} {options = ["noatime" "nodev"];}).options
        == "noatime,nodev"))
    (ck "empty options become an empty string"
      ((mount {} {}).options
        == ""))

    (ck "skipIfMissing sets ConditionPathExists on both units and drops the sugar key"
      (let
        u = unit {} {
          what = "/dev/x";
          automount = true;
          skipIfMissing = true;
        };
        m = builtins.head u.mounts;
        a = builtins.head u.automounts;
      in
        m.unitConfig.ConditionPathExists
        == "/dev/x"
        && a.unitConfig.ConditionPathExists == "/dev/x"
        && ! (builtins.hasAttr "skipIfMissing" m)
        && ! (builtins.hasAttr "skipIfMissing" a)))

    (ck "wantedBy and descriptions default, entries win"
      (let
        u = unit {} {
          what = "/dev/x";
          automount = true;
          wantedBy = ["graphical-session.target"];
          description = "Data disk";
        };
        m = builtins.head u.mounts;
        a = builtins.head u.automounts;
      in
        a.wantedBy
        == ["graphical-session.target"]
        && m.description == "Data disk"
        && a.description == "Data disk"
        && (auto {} {automount = true;}).wantedBy == ["multi-user.target"]))

    (ck "joinUnitMounts merges groups in order and yields {} on no groups"
      (let
        a = fs.mkUnitMounts {} {
          "/a" = {
            what = "/dev/a";
            automount = true;
          };
        };
        b = fs.mkUnitMounts {} {
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
