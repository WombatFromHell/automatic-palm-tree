# Output suite: the shape of flake.outputs. Every check reads attribute *names*, never a value or
# a derivation, so the whole suite stays cheap (~0.4GB). A check that forces a derivation would
# evaluate that host's toplevel: even `x.type` on a derivation costs ~700MB, because the
# derivation attrset is merged. Proving the derivations themselves is `nix flake check`'s job —
# it builds them — and that is out of this suite's memory budget on a RAM-constrained box.
# ~8s.
let
  s = import ./support.nix;
  inherit (s) lib ck suite;
  out = s.flake.outputs;
  hosts = s.hosts.discoveredHosts;

  # Derived, not hardcoded: the check set must mirror the configurations.
  # attrNames is sorted, so the derived list is sorted too.
  expectedChecks =
    lib.sort (a: b: a < b)
    ((map (h: "nixos-${h}") (lib.attrNames out.nixosConfigurations))
      ++ (map (k: "home-${k}") (lib.attrNames out.homeConfigurations)));

  # Derived from the records, mirroring builders.nix: only a standalone host
  # (isNixOS = false) produces homeConfigurations, keyed user@host.
  expectedHomeKeys =
    lib.sort (a: b: a < b)
    (lib.concatLists (map (h: map (u: "${u}@${h.name}") h.hmUsernames) (lib.filter (h: !h.isNixOS) (lib.attrValues hosts))));

  # The pin updaters run in the devShell, so the tools they need are part of the flake's
  # contract. The derivation attrset lists them as derivations; mkShell puts `packages` under
  # nativeBuildInputs, so both lists are read. shellcheck's pname is "ShellCheck", so the
  # comparison is on the lowercased pname -- the command the shell resolves is the one named.
  shell = out.devShells.x86_64-linux.default;
  shellTools = (shell.drvAttrs.nativeBuildInputs or []) ++ (shell.drvAttrs.buildInputs or []);
  hasTool = tool: lib.any (p: lib.toLower (p.pname or p.name or "") == tool) shellTools;

  checks = [
    (ck "the flake exposes configurations, checks and a devShell"
      (lib.attrNames out == ["checks" "devShells" "homeConfigurations" "nixosConfigurations"]))
    (ck "the devShell is keyed by supported system" (lib.attrNames out.devShells == ["x86_64-linux"]))
    (ck "the devShell carries the tools the pin updaters need"
      (lib.all hasTool ["curl" "jq" "nix" "bats" "shellcheck" "shfmt"]))
    (ck "checks are keyed by supported system" (lib.attrNames out.checks == ["x86_64-linux"]))
    (ck "every configuration gets a check named after it"
      (lib.attrNames out.checks.x86_64-linux == expectedChecks))
    (ck "nixosConfigurations covers exactly the isNixOS hosts"
      (lib.attrNames out.nixosConfigurations == (lib.filter (h: hosts.${h}.isNixOS) (lib.attrNames hosts))))
    (ck "homeConfigurations are keyed user@host"
      (lib.attrNames out.homeConfigurations == expectedHomeKeys))
  ];
in
  suite "outputs" checks
