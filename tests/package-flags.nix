# nix-unit attributes for the eval-time guard a feature's _package.nix puts on the flags a module
# hands it. tests/brave-layout.nix proves flags reach the wrapper verbatim; it cannot prove that a
# refused flag throws instead of being forwarded, so that is an `expectedError` attribute here
# (ADR-fb331caa521d: a must-throw check is never tryEval — a deferred error is a value).
let
  s = import ./support.nix;
  inherit (s) pkgs;

  # Called the way production does: hm-brave reads pkgs.unstable, pinMeta arrives via the overlay.
  brave = args: pkgs.unstable.callPackage ../features/hm-brave/_package.nix args;
in {
  # --no-sandbox switches the namespace sandbox off, and the sandbox works here (brave://sandbox
  # reports Layer 1 = Namespace with PID/network namespaces and seccomp-BPF TSYNC). Forcing
  # installPhase is what forces `addFlags`, which is where the guard sits.
  testBraveRefusesNoSandboxFlag = {
    expr = (brave {commandLineArgs = "--no-sandbox --password-store=basic";}).installPhase;
    expectedError = {
      type = "ThrownError";
      msg = "brave-bin refuses --no-sandbox";
    };
  };
}
