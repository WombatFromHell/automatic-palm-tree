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
# credsctl runs jq and sopsctl, sopsctl runs sops, age, jq and ssh-to-age (the passphrase of a
# protected ssh origin goes to ssh-to-age in its environment, so no askpass helper is shipped). The
# bats suites run the raw files on the host PATH, which hides exactly that, so the runtime paths are
# asserted on the built wrapper.
let
  s = import ./support.nix;
  inherit (s) pkgs;
  inherit (s.pkgs.lib) findFirst;

  creds = (import ../features/hm-creds/home.nix) {inherit pkgs;};

  # xilo's real store path is a placeholder: the marker substitution and the shellcheck are what is
  # under test, and neither needs the upstream CLI, so nothing is fetched. The wrapper is still taken
  # from hm-xilo's own module, so this guard cannot pass while the module ships something else.
  xiloCli = pkgs.writeShellScriptBin "xilo" "";

  xilo = (import ../features/hm-xilo/home.nix) {
    inherit pkgs;
    inputs = {
      xilo = {
        packages.${pkgs.stdenv.hostPlatform.system}.default = xiloCli;
      };
    };
  };

  shipped = packages: name:
    findFirst
    (p: p.name or "" == name)
    (throw "no '${name}' is shipped — the bats suite tests a script nothing installs")
    packages;

  credsctl = shipped creds.home.packages "credsctl";
  sopsctl = shipped creds.home.packages "sopsctl";
  # hm-xilo's own wrapper, marker and all — the same substitution the real profile ships.
  wrapped = shipped xilo.home.packages "xilo-wrapped";
in
  # Nothing reads a joined tree: every fact below is a grep against the wrapper's own text, and
  # interpolating a path makes it a build input already. A missing runtimeInput is a runtime
  # `command not found` nobody sees until a unit or an elevated push runs the script, which is the
  # whole point of the portable backend.
  pkgs.runCommand "shellwrap"
  {} ''
    mkdir -p "$out"
    grep -q "${pkgs.jq}/bin" "${credsctl}/bin/credsctl" ||
      { echo "credsctl: jq is not a runtimeInput, so the shipped script cannot run it" >&2; exit 1; }
    for d in ${toString [pkgs.sops pkgs.age pkgs.jq pkgs.ssh-to-age]}; do
      grep -q "$d/bin" "${sopsctl}/bin/sopsctl" ||
        { echo "sopsctl: $d is not a runtimeInput, so the shipped script cannot run it" >&2; exit 1; }
    done
    # The passphrase route is ssh-to-age's environment variable, so no askpass helper belongs on
    # the shipped PATH; KDE's is the only candidate package that kept one.
    ! grep -q 'ksshaskpass-' "${sopsctl}/bin/sopsctl" ||
      { echo "sopsctl: an askpass helper is a runtimeInput, but ssh-to-age never runs SSH_ASKPASS" >&2; exit 1; }
    # The wrapper execs the CLI by store path, baked in by hm-xilo's marker substitution. A marker
    # that survived ships a literal the shell cannot run, and every `xilo` dies at exec.
    grep -q "${xiloCli}/bin/xilo" "${wrapped}/bin/xilo-wrapped" ||
      { echo "xilo-wrapped: the __XILO_PROGRAM__ marker was not substituted, so the shipped wrapper execs a path that does not exist" >&2; exit 1; }
  ''
