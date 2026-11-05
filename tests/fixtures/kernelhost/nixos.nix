# A host-local module that pins the kernel: exactly what lib/builders.nix must catch
# alongside a kernel feature. The value is a placeholder - the guard reads the module's
# shape, and nothing here is evaluated past the throw. A plain attrset module, not
# `{...}: {}`: statix wants `{_}`, and `{_}` throws when the module system calls the
# file with {config, lib, pkgs, ...}.
{
  boot.kernelPackages = "placeholder-not-a-package-set";
}
