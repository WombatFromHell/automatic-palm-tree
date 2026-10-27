# Fixture home module, referenced by hosts/flat.nix as an author-declared
# homeModules entry. Never evaluated by the loader suite.
# Empty attrset module: `{_}: {}` would throw when the module system calls it.
{}
