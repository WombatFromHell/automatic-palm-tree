# Fixture: flat host record exercising user gating.
# Host files are modules: lib/hosts.nix imports them with hostLib in scope.
{hostLib, ...}: {
  system = "x86_64-linux";
  users = {
    alice = {isAdmin = true;};
    bob = {hmEnabled = false;};
    # Disabled, so it must never reach osUsernames or adminUsernames even though it is an admin.
    carol = {
      isAdmin = true;
      enabled = false;
    };
  };
  # Both users have a home module key, so only alice should reach hmUsernames
  # (bob is gated off by hmEnabled, carol by enabled). alice is the only admin:
  # bob is enabled but not an admin, carol is not enabled at all. The lists stay
  # empty: the loader derives usernames from the keys and never evaluates them.
  homeModules = {
    alice = [];
    bob = [];
  };
}
