# A host-local module that pins the kernel: exactly what lib/builders.nix must catch
# alongside a kernel feature. The value is a placeholder - the guard reads the module's
# shape, and nothing here is evaluated past the throw.
{...}: {
  boot.kernelPackages = "placeholder-not-a-package-set";
}
