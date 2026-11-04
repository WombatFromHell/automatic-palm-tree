# expect: does not exist
# `name`, `osUsernames`, `adminUsernames` and `hmUsernames` are derived by lib/hosts.nix,
# so a host file that sets one of them must be rejected rather than shadowed.
((import ../support.nix).hostsAt ../fixtures/derivedname).discoveredHosts.authoredName
