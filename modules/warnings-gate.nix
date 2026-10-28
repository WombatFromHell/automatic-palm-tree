# modules/warnings-gate.nix — make any configuration warning fail the build.
#
# A warning is printed, never fatal: `lib.asserts.checkAssertWarn` throws only on failed
# assertions, and forcing the toplevel (`config.system.build.toplevel`, or Home Manager's
# `activationPackage`) already forces `config.assertions` *and* `config.warnings`. Asserting the
# warnings list therefore costs nothing at eval — `checkAssertWarn` only forces an assertion's
# `message` when it failed — and turns `nix build`, `nix flake check` and `nixos-rebuild switch`
# into a failure before any builder runs.
#
# A warning that is genuinely unavoidable (an upstream deprecation, say) is filtered by prefix
# here; deleting the assertion would drop the invariant.
{
  config,
  lib,
  ...
}:
{
  assertions = [
    {
      assertion = config.warnings == [];
      message = "configuration warnings:\n${lib.concatStringsSep "\n" config.warnings}";
    }
  ];
}
