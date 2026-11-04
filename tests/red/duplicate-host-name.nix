# expect: Two host definitions
# hosts/x.nix beside hosts/x/default.nix would silently shadow one another.
((import ../support.nix).hostsAt ../fixtures/duplicate).discoveredHosts.dup
