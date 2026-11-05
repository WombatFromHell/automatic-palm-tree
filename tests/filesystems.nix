# nix-unit attributes for lib/filesystems.nix — the whole filesystems contract in one file, so a
# failing attribute prints its own diff instead of naming the suite. Pure: only the lib is
# evaluated, no host config forced.
#
# The attributes whose value must throw carry `expectedError` (type + message substring), which is
# what the guards that used to live in tests/red/ asserted. The types are the ones nix-unit
# reports here: `TypeError` when `//` or `++` gets the wrong shape, `EvalError` for a missing
# attribute, `ThrownError` for a `throw`.
let
  s = import ./support.nix;
  inherit (s) lib fs;

  mk = defaults: entry: (fs.mkMounts defaults {"/m" = entry;})."/m";
  # One mount point, both units from one eval. Attributes that need a specific path (the escaped
  # unit name and joinUnitMounts) call fs.mkUnitMounts directly, since the name is derived
  # from the path.
  unit = defaults: entry: fs.mkUnitMounts defaults {"/mnt/x" = entry;};
  mount = defaults: entry: builtins.head (unit defaults entry).mounts;
  auto = defaults: entry: builtins.head (unit defaults entry).automounts;

  # The pairing the escaping exists for: the mount names the automount systemd will create.
  escaped = fs.mkUnitMounts {} {
    "/mnt/a-b" = {
      what = "/dev/a";
      automount = true;
    };
  };
  escapedAutomount = "mnt-a\\x2db.automount";

  configPass = unit {} {
    what = "/dev/x";
    automount = true;
    mountConfig = {TimeoutSec = 5;};
    unitConfig = {ConditionPathExists = "/dev/x";};
  };
  skipUnit = unit {} {
    what = "/dev/x";
    automount = true;
    skipIfMissing = true;
  };
  namedUnit = unit {} {
    what = "/dev/x";
    automount = true;
    wantedBy = ["graphical-session.target"];
    description = "Data disk";
  };
  joined = fs.joinUnitMounts [
    (fs.mkUnitMounts {} {
      "/a" = {
        what = "/dev/a";
        automount = true;
      };
    })
    (fs.mkUnitMounts {} {
      "/b" = {
        what = "/dev/b";
        automount = true;
      };
    })
  ];
in
  {
    # --- mkMounts -> `fileSystems` attrsets ---------------------------------
    testEntryKeysWinOverDefaults = {
      expr = mk {
        device = "/dev/a";
        fsType = "ext4";
      } {
        device = "/dev/b";
        fsType = "vfat";
      };
      expected = {
        device = "/dev/b";
        fsType = "vfat";
      };
    };
    # `options` is NixOS semantics: an entry replaces the defaults, it does not extend them.
    testEntryOptionsReplaceDefaults = {
      expr = mk {options = ["noatime"];} {options = ["nodev"];};
      expected = {options = ["nodev"];};
    };
    testDefaultsOptionsSurviveEmptyEntry = {
      expr = mk {options = ["noatime"];} {};
      expected = {options = ["noatime"];};
    };
    testSubvolAppendedLast = {
      expr = mk {options = ["noatime"];} {subvol = "@";};
      expected = {options = ["noatime" "subvol=@"];};
    };
    testSubvolNullAddsNothing = {
      expr = mk {options = ["noatime"];} {subvol = null;};
      expected = {options = ["noatime"];};
    };
    # An empty option list is dropped so NixOS defaults apply.
    testEmptyOptionListIsDropped = {
      expr = mk {} {};
      expected = {};
    };
    # A mount entry is an attrset; the bare-string shorthand only exists on mkUnitMounts, so
    # mkMounts must reject it instead of merging a string.
    testMountsRejectsDeviceAsString = {
      expr = (fs.mkMounts {fsType = "ext4";} {"/m" = "/dev/x";})."/m";
      expectedError = {
        type = "TypeError";
        msg = "expected a set but found a string";
      };
    };
    # `options` is a list; a string must throw rather than be joined into one option.
    testMountsOptionsMustBeList = {
      expr = (fs.mkMounts {} {"/m" = {options = "noatime";};})."/m".options;
      expectedError = {
        type = "TypeError";
        msg = "expected a list but found a string";
      };
    };

    # --- unit names ---------------------------------------------------------
    # The unit name is what systemd derives from the mount point, so '-' and a space must be
    # escaped, not swapped for a dash: '/mnt/a-b' would otherwise name the unit of '/mnt/a/b'
    # and pair with the wrong automount.
    testUnitNameEscapesDash = {
      expr = fs.unitName "/mnt/a-b";
      expected = "mnt-a\\x2db";
    };
    testUnitNameEscapesSpace = {
      expr = fs.unitName "/mnt/a b";
      expected = "mnt-a\\x20b";
    };
    testUnitNamePlainPath = {
      expr = fs.unitName "/mnt/a/b";
      expected = "mnt-a-b";
    };
    # systemd-escape refuses a path it cannot resolve without the filesystem. The old
    # slash-swap happily wrote `mnt-..-x.mount`, a unit that fails at boot with no error at
    # eval, so mkUnitMounts must surface nixpkgs' own refusal instead.
    testUnitEscapeRejectsUnnormalizedPath = {
      expr = builtins.head
        (builtins.head (fs.mkUnitMounts {} {
          "/mnt/../x" = {
            what = "/dev/a";
            automount = true;
          };
        }).mounts).requires;
      expectedError = {
        type = "ThrownError";
        msg = "not a normalized path";
      };
    };

    # --- mkUnitMounts -> { mounts, automounts }, both LISTS -----------------
    testStringShorthandSetsWhatAndKeepsDefaults = {
      expr = mount {type = "btrfs";} "/dev/x";
      expected = {
        what = "/dev/x";
        type = "btrfs";
        where = "/mnt/x";
        description = "Mount for /mnt/x";
        options = "";
      };
    };
    # Entries are attrsets; the string shorthand is the only non-set form accepted, so a number
    # must throw rather than coerce.
    testUnitEntryMustBeSet = {
      expr = builtins.head (fs.mkUnitMounts {} {"/mnt/x" = 42;}).mounts;
      expectedError = {
        type = "TypeError";
        msg = "expected a set but found an integer";
      };
    };
    # Same contract on the unit-mount path: `options` is a list before it is joined into the
    # mount's comma-separated option string.
    testUnitOptionsMustBeList = {
      expr = (builtins.head (fs.mkUnitMounts {} {"/mnt/x" = {options = "rw";};}).mounts).options;
      expectedError = {
        type = "TypeError";
        msg = "expected a list but found a string";
      };
    };

    # automount defaults to false: no automount unit, no requires, no after.
    testAutomountDefaultsToNoAutomounts = {
      expr = (unit {} {}).automounts;
      expected = [];
    };
    testAutomountDefaultsToNoRequires = {
      expr = builtins.head (unit {} {}).mounts ? requires;
      expected = false;
    };
    testAutomountDefaultsToNoAfter = {
      expr = builtins.head (unit {} {}).mounts ? after;
      expected = false;
    };
    # automount adds <unit>.automount to the mount's requires and after.
    testAutomountAddsUnitToRequires = {
      expr = (mount {} {
        what = "/dev/x";
        automount = true;
      }).requires;
      expected = ["mnt-x.automount"];
    };
    testAutomountAddsUnitToAfter = {
      expr = (mount {} {
        what = "/dev/x";
        automount = true;
      }).after;
      expected = ["mnt-x.automount"];
    };
    # The cycle guard: the automount is a lazy trigger, never a dependent.
    testAutomountWhitelistsKeys = {
      expr = builtins.attrNames
        (auto {} {
          what = "/dev/x";
          type = "btrfs";
          automount = true;
          requires = ["network-online.target"];
          after = ["network-online.target"];
          options = ["rw"];
        });
      expected = ["description" "wantedBy" "where"];
    };

    # unitConfig and mountConfig pass by value; mountConfig stays on the mount.
    testMountPassesMountConfig = {
      expr = (builtins.head configPass.mounts).mountConfig;
      expected = {TimeoutSec = 5;};
    };
    testMountPassesUnitConfig = {
      expr = (builtins.head configPass.mounts).unitConfig;
      expected = {ConditionPathExists = "/dev/x";};
    };
    testAutomountPassesUnitConfig = {
      expr = (builtins.head configPass.automounts).unitConfig;
      expected = {ConditionPathExists = "/dev/x";};
    };
    testAutomountHasNoMountConfig = {
      expr = (builtins.head configPass.automounts) ? mountConfig;
      expected = false;
    };

    # Options become a comma string; an empty list becomes an empty string.
    testOptionsBecomeCommaString = {
      expr = (mount {} {options = ["noatime" "nodev"];}).options;
      expected = "noatime,nodev";
    };
    testEmptyOptionsBecomeEmptyString = {
      expr = (mount {} {}).options;
      expected = "";
    };

    # skipIfMissing sets ConditionPathExists on both units and drops the sugar key.
    testSkipIfMissingSetsMountCondition = {
      expr = (builtins.head skipUnit.mounts).unitConfig.ConditionPathExists;
      expected = "/dev/x";
    };
    testSkipIfMissingSetsAutomountCondition = {
      expr = (builtins.head skipUnit.automounts).unitConfig.ConditionPathExists;
      expected = "/dev/x";
    };
    testSkipIfMissingDroppedFromMount = {
      expr = (builtins.head skipUnit.mounts) ? skipIfMissing;
      expected = false;
    };
    testSkipIfMissingDroppedFromAutomount = {
      expr = (builtins.head skipUnit.automounts) ? skipIfMissing;
      expected = false;
    };
    # skipIfMissing writes ConditionPathExists = what, so it needs a device: without `what` the
    # deferred error must surface at eval, not in the unit file.
    testSkipIfMissingWithoutWhatThrows = {
      expr = builtins.head
        (builtins.head (fs.mkUnitMounts {} {
          "/mnt/x" = {
            automount = true;
            skipIfMissing = true;
          };
        }).mounts).unitConfig.ConditionPathExists;
      expectedError = {
        type = "EvalError";
        msg = "attribute 'what' missing";
      };
    };

    # wantedBy and descriptions default, entries win.
    testAutomountWantedByEntryWins = {
      expr = (builtins.head namedUnit.automounts).wantedBy;
      expected = ["graphical-session.target"];
    };
    testMountDescriptionEntryWins = {
      expr = (builtins.head namedUnit.mounts).description;
      expected = "Data disk";
    };
    testAutomountDescriptionEntryWins = {
      expr = (builtins.head namedUnit.automounts).description;
      expected = "Data disk";
    };
    testWantedByDefaultIsMultiUser = {
      expr = (auto {} {automount = true;}).wantedBy;
      expected = ["multi-user.target"];
    };

    # An automount at a path containing '-' pairs with the escaped unit.
    testEscapedAutomountInRequires = {
      expr = lib.elem escapedAutomount (builtins.head escaped.mounts).requires;
      expected = true;
    };
    testEscapedAutomountInAfter = {
      expr = lib.elem escapedAutomount (builtins.head escaped.mounts).after;
      expected = true;
    };
    testEscapedAutomountWhere = {
      expr = (builtins.head escaped.automounts).where;
      expected = "/mnt/a-b";
    };

    # joinUnitMounts merges groups in order and yields {} on no groups.
    testJoinUnitMountsEmptyGivesEmpty = {
      expr = fs.joinUnitMounts [];
      expected = {};
    };
    testJoinUnitMountsKeepsMountOrder = {
      expr = map (m: m.where) joined.mounts;
      expected = ["/a" "/b"];
    };
    testJoinUnitMountsKeepsAutomountOrder = {
      expr = map (m: m.where) joined.automounts;
      expected = ["/a" "/b"];
    };
  }
