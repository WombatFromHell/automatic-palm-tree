# Output suite: the shape of flake.outputs. Every check reads attribute *names*, never a value or
# a derivation, so the whole suite stays cheap (~0.4GB). A check that forces a derivation would
# evaluate that host's toplevel: even `x.type` on a derivation costs ~700MB, because the
# derivation attrset is merged. Proving the derivations themselves is `nix flake check`'s job —
# it builds them — and that is out of this suite's memory budget on a RAM-constrained box.
# Exceptions: the devShell and the apps are tiny derivations (mkShell / a shell script), so
# reading their attrsets is what proves the tools and the wording without a host toplevel.
# ~1.1s.
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

  # cache-check is the eval-only pre-flight (lib/cache-check.sh). It filters the warnings
  # modules/caches.nix writes, so the script it runs must carry that prefix, not paraphrase it.
  cacheCheck = out.apps.x86_64-linux.cache-check;
  cacheScript = builtins.readFile ../lib/cache-check.sh;

  # style is the format+lint app (lib/style.sh): the formatters rewrite files, so it is a developer
  # command rather than a gate step, but the app shape and the pipeline it runs are contract.
  styleApp = out.apps.x86_64-linux.style;
  styleScript = builtins.readFile ../lib/style.sh;

  checks = [
    (ck "the flake exposes configurations, checks, apps and a devShell"
      (lib.attrNames out
        == [
          "apps"
          "checks"
          "devShells"
          "homeConfigurations"
          "nixosConfigurations"
        ]))
    (ck "the devShell is keyed by supported system" (lib.attrNames out.devShells == ["x86_64-linux"]))
    (ck "the devShell carries the tools the pin updaters need"
      (lib.all hasTool ["curl" "jq" "nix" "bats" "shellcheck" "shfmt"]))
    # Keyed by the same systems the devShell covers, i.e. every system a host runs on.
    (ck "cache-check exists on every supported system"
      (lib.attrNames out.apps
        == lib.attrNames out.devShells
        && lib.all (system: builtins.hasAttr "cache-check" out.apps.${system}) (lib.attrNames out.apps)))
    # An app, not a bare derivation: `nix run` needs {type = "app"; program = <exe path>}.
    (ck "cache-check is a runnable app whose script filters the module's own warnings"
      (cacheCheck.type
        == "app"
        && lib.hasSuffix "cache-check" cacheCheck.program
        && lib.hasInfix "flakeCache:" cacheScript))
    (ck "style exists on every supported system"
      (lib.attrNames out.apps
        == lib.attrNames out.devShells
        && lib.all (system: builtins.hasAttr "style" out.apps.${system}) (lib.attrNames out.apps)))
    # The pipeline covers everything the flake ships: nix (fd -> alejandra -> statix), shell
    # (fd -> shfmt -> shellcheck) and markdown (oxfmt, which selects its own files). The tools ship
    # through the app's runtimeInputs, not the host profile, and a script that dropped a pass would
    # pass a grep of the flake.
    (ck "style is a runnable app that formats then lints nix, shell and markdown"
      (styleApp.type
        == "app"
        && lib.hasSuffix "style" styleApp.program
        && lib.hasInfix "alejandra" styleScript
        && lib.hasInfix "statix" styleScript
        && lib.hasInfix "shfmt" styleScript
        && lib.hasInfix "shellcheck" styleScript
        && lib.hasInfix "oxfmt" styleScript
        && lib.hasInfix "fd" styleScript))
    (ck "checks are keyed by supported system" (lib.attrNames out.checks == ["x86_64-linux"]))
    (ck "every configuration gets a check named after it"
      (lib.attrNames out.checks.x86_64-linux == expectedChecks))
    (ck "nixosConfigurations covers exactly the isNixOS hosts"
      (lib.attrNames out.nixosConfigurations
        == (lib.filter (h: hosts.${h}.isNixOS) (lib.attrNames hosts))))
    (ck "homeConfigurations are keyed user@host"
      (lib.attrNames out.homeConfigurations == expectedHomeKeys))
  ];
in
  suite "outputs" checks
