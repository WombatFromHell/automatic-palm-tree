# Build-tier guard for the scripts Home Manager ships: features/hm-creds/credsctl.sh,
# features/hm-creds/sopsctl.sh and features/hm-xilo/xilo.sh. The bats suites exercise the raw files;
# what ships is `pkgs.writeShellApplication`, which wraps them and runs nixpkgs' shellcheck on the
# wrapped text. So this builds the shipped forms and tests/run.sh gates on the build's exit status —
# a lint error in the shipped form fails here, not only in a local `shellcheck` run nobody runs.
#
# The wrappers are taken from the feature modules themselves, not re-declared here, so this guard
# cannot pass while the module ships something that does not run.
#
# The second half is the runtime PATH. writeShellApplication exports `PATH="$deps/bin:$PATH"`, so a
# command a script runs must be named in `runtimeInputs` or the shipped binary cannot find it:
# credsctl runs jq and sopsctl, sopsctl runs sops, age and jq. The bats suites run the raw files on
# the host PATH, which hides exactly that, so the runtime paths are asserted on the built wrapper.
#
# xilo's real store path is a placeholder: the marker substitution and the shellcheck are what is
# under test, and neither needs the upstream CLI, so nothing is fetched.
let
  s = import ./support.nix;
  inherit (s) pkgs;
  inherit (s.pkgs.lib) findFirst;

  creds = (import ../features/hm-creds/home.nix) { inherit pkgs; };

  shipped = name:
    findFirst
      (p: p.name or "" == name)
      (throw "hm-creds ships no '${name}' — the bats suite tests a script nothing installs")
      creds.home.packages;
in
pkgs.symlinkJoin {
  name = "shellwrap";
  paths = [
    (shipped "credsctl")
    (shipped "sopsctl")
    (pkgs.writeShellApplication {
      name = "xilo-wrapped";
      text = builtins.replaceStrings ["__XILO_PROGRAM__"]
        ["${pkgs.writeShellScriptBin "xilo" ""}/bin/xilo"] (builtins.readFile ../features/hm-xilo/xilo.sh);
    })
    # A missing runtimeInput is a runtime `command not found` nobody sees until a unit or an elevated
    # push runs the script, which is the whole point of the portable backend.
    (pkgs.runCommand "shellwrap-deps"
      { } ''
        mkdir -p "$out"
        grep -q "${pkgs.jq}/bin" "${shipped "credsctl"}/bin/credsctl" ||
          { echo "credsctl: jq is not a runtimeInput, so the shipped script cannot run it" >&2; exit 1; }
        for d in ${toString (map (d: pkgs.${d}) ["sops" "age" "jq"])}; do
          grep -q "$d/bin" "${shipped "sopsctl"}/bin/sopsctl" ||
            { echo "sopsctl: $d is not a runtimeInput, so the shipped script cannot run it" >&2; exit 1; }
        done
      '')
  ];
}
