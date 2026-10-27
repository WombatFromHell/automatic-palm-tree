# Discovered as a nixos module by lib/hosts.nix; never evaluated by the tests.
# Empty attrset, not `{...}: {}`: statix wants `{_}`, which throws when the
# module system calls the file with {config, lib, pkgs, ...}.
{}
