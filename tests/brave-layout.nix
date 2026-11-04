# Build-tier guard for features/hm-brave/_package.nix. What a derivation puts in $out is not an
# evaluated value, so this re-runs the derivation's *real* installPhase over a synthetic rpm
# payload: nothing is compiled and no package is fetched. The payload's binaries are copies of a
# store ELF, because patchelf refuses a text file -- that is the one thing the fixture cannot
# fake, and a patchelf failure fails the build itself rather than an assertion here. The copies
# are mode 755 (install -m), not the read-only 555 a plain cp of a store binary keeps.
#
# Gated by tests/run.sh on the build's exit status, not on an evaluated value.
let
  s = import ./support.nix;
  inherit (s) pkgs lib;

  # `src` is never read: unpackPhase below is replaced, so a placeholder keeps the derivation
  # honest without fetching the rpm.
  placeholderSrc = pkgs.writeTextDir "brave.rpm" "";

  # The rpm payload layout installPhase reads: opt/ carries the app, usr/share the desktop
  # entries. One ELF per path patchelf touches, plus the icon sed/install reads.
  elf = pkgs.coreutils;
  binaries = ["brave" "brave-browser" "brave_crashpad_handler" "libbrave.so.1"];

  extracted =
    (pkgs.unstable.callPackage ../features/hm-brave/_package.nix {}).overrideAttrs
    (_final: _prev: {
      src = placeholderSrc;
      unpackPhase = ''
        mkdir -p opt/brave.com/brave usr/share/applications
        ${lib.concatMapStringsSep "\n" (b: "install -m755 ${elf}/bin/ls opt/brave.com/brave/${b}") binaries}

        printf '[Desktop Entry]\nType=Application\nName=Brave\nExec=/usr/bin/brave-browser-stable\n' \
          > usr/share/applications/com.brave.Browser.desktop
        printf '[Desktop Entry]\nType=Application\nName=Brave\nExec=/usr/bin/brave-browser-stable\n' \
          > usr/share/applications/brave-browser.desktop
        printf 'png' > opt/brave.com/brave/product_logo_128.png
      '';
    });
in
  pkgs.runCommand "brave-store-layout" {dependsOn = [extracted];} ''
    set -e
    P=${extracted}

    # The app lives under opt/ and bin/ resolves to it: Home Manager's programs.chromium
    # reads programs.chromium.package, so a broken symlink is a browser that will not start.
    test -x "$P/opt/brave.com/brave/brave"
    test -x "$P/bin/brave"
    test -x "$P/bin/brave-browser"
    test "$(readlink "$P/bin/brave")" = "$P/opt/brave.com/brave/brave"

    # Desktop entries move into share/ and lose the rpm's absolute Exec, which points at a
    # path nothing in the store has.
    test -e "$P/share/applications/com.brave.Browser.desktop"
    test -e "$P/share/applications/brave-browser.desktop"
    grep -q '^Exec=brave-browser$' "$P/share/applications/com.brave.Browser.desktop"
    grep -q '^Exec=brave-browser$' "$P/share/applications/brave-browser.desktop"
    grep -qv '/usr/bin/' "$P/share/applications/brave-browser.desktop"

    # The icon is installed where the desktop search paths look, and the rpm's usr/ is gone.
    test -e "$P/share/icons/hicolor/128x128/apps/brave-browser.png"
    test ! -e "$P/usr"

    mkdir -p $out
  ''
