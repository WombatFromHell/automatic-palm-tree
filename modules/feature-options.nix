# Feature-option namespace: every feature module may read these options, and the
# two builders apply this module to both the NixOS and the Home Manager namespace.
{
  lib,
  config,
  options,
  ...
}: {
  options = {
    extraGroups = lib.mkOption {
      # attrset (feature -> [groups]) so multiple features merge by key, not last-wins
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      internal = true;
      description = "Groups to add isAdmin-enabled users to when this feature is enabled.";
    };
  };

  config.warnings = lib.optionals (config.extraGroups != {} && !(lib.hasAttrByPath ["users" "users"] options)) [
    "Feature module declares extraGroups ${builtins.toJSON config.extraGroups} but 'users.users' is unavailable in standalone home-manager modules."
  ];
}
