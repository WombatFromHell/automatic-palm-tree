# Mount description helper: one defaults attrset, one short entry per mount, so a host
# repeats a device and fsType once instead of on every mount. Filesystem-agnostic — fsType,
# options and any other `fileSystems.<mount>` attr pass straight through untouched.
{lib}: {
  # A mount that names `options` replaces the defaults (NixOS's own default semantics), which
  # is what keeps `/boot` on vfat correct. `options` must be a list of non-empty strings —
  # NixOS rejects a string here (strings belong to systemd mount units, not `fileSystems`).
  # `subvol` is sugar for one extra option and is dropped from the result; if a mount has a
  # subvol but nothing else to say about options, it gets just `subvol=…`.
  mkMounts = defaults: mounts:
    lib.mapAttrs (
      _mount: mount: let
        inherit (builtins) isString removeAttrs;
        options =
          (mount.options or defaults.options or [])
          ++ lib.optional (isString (mount.subvol or null)) "subvol=${mount.subvol}";
      in
        removeAttrs (defaults // removeAttrs mount ["subvol"]) ["options"]
        // lib.optionalAttrs (options != []) {inherit options;}
    )
    mounts;

  # systemd `.mount` / `.mount+.automount` units. Keyed by the mount path — systemd derives the
  # unit name from `where`, so `systemd.mounts`/`systemd.automounts` are LISTS: compose blocks
  # with `++`, never `//`. Unit `options` is a comma string here (`types.commas` rejects a list),
  # so pass a list and this joins it; entry `options` replaces the defaults exactly like
  # `mkMounts`, so extend with `options = defaults.options ++ [...]`. `subvol` is sugar for one
  # extra option. `automount = true` emits the paired `.automount` unit and links the mount to it;
  # an automount declares only `where`/`description`/`wantedBy` (+deps), so `what`/`type`/`options`
  # are stripped from it — leaving them there is an eval error.
  mkUnitMounts = defaults: units: let
    inherit (builtins) attrValues isString mapAttrs removeAttrs replaceStrings stringLength substring;
    inherit (lib) concatStringsSep filterAttrs optional optionalAttrs;
    automountName = where: replaceStrings ["/"] ["-"] (substring 1 (stringLength where - 1) where);
    joinOptions = u:
      concatStringsSep ","
      ((u.options or defaults.options or [])
        ++ optional (isString (u.subvol or null)) "subvol=${u.subvol}");
    mount = where: u:
      (defaults // removeAttrs u ["automount" "subvol"])
      // {
        inherit where;
        description = u.description or defaults.description or "Mount for ${where}";
        options = joinOptions u;
      }
      // optionalAttrs (u.automount or false) {
        requires = (u.requires or defaults.requires or []) ++ ["${automountName where}.automount"];
        after = (u.after or defaults.after or []) ++ ["${automountName where}.automount"];
      };
    automount = where: u:
      removeAttrs (defaults // removeAttrs u ["automount" "subvol"]) ["what" "type" "options"]
      // {
        inherit where;
        description = u.description or defaults.description or "Automount for ${where}";
        wantedBy = u.wantedBy or ["multi-user.target"];
      };
  in {
    mounts = attrValues (mapAttrs mount units);
    automounts = attrValues (mapAttrs automount (filterAttrs (_: u: u.automount or false) units));
  };
}
