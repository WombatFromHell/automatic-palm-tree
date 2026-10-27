# Mount description helpers: one defaults attrset, one short entry per mount, so a host
# repeats a device and fsType once. Filesystem-agnostic: everything except the sugar keys
# below passes straight through to the target attrset.
#
# `options` is a list; an entry's `options` replaces the defaults' (NixOS semantics, keeps
# `/boot` on vfat correct). `subvol` is sugar for one trailing `subvol=…` option. Sugar keys
# may sit in defaults or on an entry.
{lib}: let
  inherit (builtins) intersectAttrs isString removeAttrs replaceStrings;
  inherit (lib) concatStringsSep filterAttrs mapAttrs mapAttrsToList optional optionalAttrs removePrefix zipAttrsWith concatLists;

  merge = defaults: entry: let
    all = defaults // entry;
  in
    removeAttrs all ["subvol" "options"]
    // {
      options =
        (all.options or [])
        ++ optional (isString (all.subvol or null)) "subvol=${all.subvol}";
    };

  # ponytail: assumes paths without `-` or special chars; use
  # `utils.escapeSystemdPath` (NixOS module arg) if a mount point ever needs them.
  unitName = where: replaceStrings ["/"] ["-"] (removePrefix "/" where);
in {
  # -> attrset for `fileSystems`. An empty option list is dropped so NixOS defaults apply.
  mkMounts = defaults:
    mapAttrs (
      _: entry: let
        m = merge defaults entry;
      in
        if m.options == []
        then removeAttrs m ["options"]
        else m
    );

  # -> { mounts, automounts }, both LISTS (systemd derives unit names from `where`); combine
  # groups with `joinUnitMounts`, never `//`.
  #
  # Sugar, on top of `options`/`subvol`:
  #   "/mnt/x" = "dev";       shorthand for { what = "dev"; }
  #   automount = true;       emits the paired `.automount`; the mount requires/follows it
  #   skipIfMissing = true;   skips the mount and automount when `what` doesn't exist at
  #                           unit start (ConditionPathExists)
  #   (ponytail: checked once, so a device plugged in later needs a unit restart)
  #
  # The automount is only a lazy trigger, so it keeps just `description`, `wantedBy`,
  # `unitConfig` and `automountConfig`. Mount-side deps (`requires`, `after`, ...) must not
  # leak onto it: a `network-online.target` dependency there closes an ordering cycle
  # through `local-fs.target`.
  mkUnitMounts = defaults: units: let
    entries =
      mapAttrs (
        _: u: let
          m = merge defaults (
            if isString u
            then {what = u;}
            else u
          );
        in
          removeAttrs m ["skipIfMissing"]
          // optionalAttrs (m.skipIfMissing or false) {
            unitConfig = (m.unitConfig or {}) // {ConditionPathExists = m.what;};
          }
      )
      units;

    mount = where: m:
      removeAttrs m ["automount"]
      // {
        inherit where;
        description = m.description or "Mount for ${where}";
        options = concatStringsSep "," m.options;
      }
      // optionalAttrs (m.automount or false) (let
        dep = ["${unitName where}.automount"];
      in {
        requires = (m.requires or []) ++ dep;
        after = (m.after or []) ++ dep;
      });

    automount = where: m:
      intersectAttrs {
        unitConfig = null;
        automountConfig = null;
      }
      m
      // {
        inherit where;
        description = m.description or "Automount for ${where}";
        wantedBy = m.wantedBy or ["multi-user.target"];
      };
  in {
    mounts = mapAttrsToList mount entries;
    automounts = mapAttrsToList automount (filterAttrs (_: m: m.automount or false) entries);
  };

  # [ mkUnitMounts result ] -> `{ mounts, automounts }`, ready to assign to `systemd`.
  joinUnitMounts = zipAttrsWith (_: concatLists);
}
