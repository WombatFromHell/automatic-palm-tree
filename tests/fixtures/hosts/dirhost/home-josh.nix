# Fixture: discovered as the "josh" home module by lib/hosts.nix.
# Never built by the tests; discovery and user derivation are what matter.
# Empty attrset module: `{_}: {}` would throw when the module system calls it.
{}
