# Build-tier guard for features/hm-brave/_package.nix. What a derivation puts in $out is not an
# evaluated value, so this re-runs the derivation's *real* unpackPhase and installPhase over a
# synthetic .deb assembled by tar + ar: nothing is compiled and no browser is fetched. The
# binaries are copies of a store ELF (mode 755 via `install -m`, not the read-only 555 a plain cp
# of a store binary keeps), because patchelf refuses a text file -- that is the one thing the
# fixture cannot fake, and a patchelf failure fails the build itself rather than an assertion
# here. `brave-browser` is faked faithfully: the deb ships it as a #!/bin/bash script, and a
# script whose shebang still points at /bin/bash is a browser that will not start off NixOS.
#
# Gated by tests/run.sh on the build's exit status, not on an evaluated value.
let
  s = import ./support.nix;
  inherit (s) pkgs;

  # A real store ELF: patchelf needs real ELF bytes, and every patched file has to be one. It
  # also has to *run* after patchelf replaces its rpath with the browser's library list, which
  # carries no gmp/readline -- coreutils `ls` dies with "libgmp.so.10 missing" once patched, so
  # the fixture app is `patch`, whose only libraries are the glibc the interpreter supplies and
  # libstdc++ that the declared rpath does include.
  elf = pkgs.gnupatch;

  # The deb payload unpackPhase and installPhase read, assembled the way dpkg-deb would: an ar
  # archive of debian-binary + control.tar.gz + data.tar.gz. Built by hand rather than with
  # `dpkg-deb -b` because the payload has to carry chrome-sandbox's *recorded* mode -- root-owned
  # setuid. A builder running as nixbld cannot put that bit on a file it created (the sandbox
  # refuses the chmod), so `tar --mode` records it in the header instead. Without that entry the
  # fixture cannot reproduce the thing that broke: `dpkg-deb -x` preserves modes and dies on the
  # chmod, exactly as Brave's real deb does.
  deb =
    pkgs.runCommand "brave-deb-fixture" {
      nativeBuildInputs = [pkgs.dpkg pkgs.binutils pkgs.gzip];
    } ''
      mkdir -p payload/opt/brave.com/brave payload/usr/share/applications DEBIAN

      for b in brave chrome_crashpad_handler libbrave.so.1; do
        install -m755 ${elf}/bin/patch payload/opt/brave.com/brave/$b
      done
      install -m755 ${elf}/bin/patch payload/opt/brave.com/brave/chrome-sandbox

      printf '#!/bin/bash\nHERE="$(dirname "$0")"\nexec "$HERE/brave" "$@"\n' \
        > payload/opt/brave.com/brave/brave-browser
      chmod 755 payload/opt/brave.com/brave/brave-browser
      printf 'png' > payload/opt/brave.com/brave/product_logo_128.png

      for d in com.brave.Browser brave-browser; do
        printf '[Desktop Entry]\nType=Application\nName=Brave\nExec=/usr/bin/brave-browser-stable\n' \
          > payload/usr/share/applications/$d.desktop
      done

      printf 'Package: brave-browser\nVersion: 0\nArchitecture: amd64\n' > DEBIAN/control

      # chrome-sandbox ships root-owned setuid. tar's --mode is global, so every entry is recorded
      # that way -- stricter than the real deb, and any extraction that preserves modes fails on it.
      tar --mode=4755 --owner=root --group=root --numeric-owner -cf data.tar -C payload .
      gzip -n data.tar
      tar -cf control.tar -C DEBIAN .
      gzip -n control.tar
      printf '2.0\n' > debian-binary
      ar -rcD "brave-browser_0_amd64.deb" debian-binary control.tar.gz data.tar.gz

      cp "brave-browser_0_amd64.deb" "$out"
    '';

  # The derivation under test, with the pinned download swapped for the fixture payload.
  underTest = args:
    (pkgs.unstable.callPackage ../features/hm-brave/_package.nix args).overrideAttrs
    (_final: _prev: {src = deb;});

  plain = underTest {};
  # Flags arrive from programs.chromium's override as one string. The `$(id)` and the quote are
  # the injection: substituted unescaped they execute at build time.
  flagged = underTest {commandLineArgs = "--password-store=basic --flag=$(id) --quote=\"x\"";};
in
  pkgs.runCommand "brave-store-layout" {
    dependsOn = [plain flagged];
    nativeBuildInputs = [pkgs.patchelf];
  } ''
    set -e
    P=${plain}
    W=${flagged}

    # The app lives under opt/. bin/ entries are wrappers, not symlinks: they carry the GL
    # driver path, xdg-utils on PATH and the flags Home Manager overrides the package with.
    test -x "$P/opt/brave.com/brave/brave"
    test -x "$P/bin/brave"
    test ! -L "$P/bin/brave"
    test -x "$P/bin/brave-browser"
    test ! -L "$P/bin/brave-browser"
    grep -qa "$P/opt/brave.com/brave/brave" "$P/bin/brave"
    grep -qa "$P/opt/brave.com/brave/brave-browser" "$P/bin/brave-browser"
    grep -qa xdg-utils "$P/bin/brave"
    # The GPU driver directory, which is what addDriverRunpath's setup hook hands the wrapper.
    grep -qa "${pkgs.addDriverRunpath.driverLink}/lib" "$P/bin/brave"
    # The wrapper is compiled, so prove it runs: the fixture's app is `patch`.
    "$P/bin/brave" --version | grep -q 'GNU patch'

    # The setuid helper extracts without the suid bit: Chrome uses the namespace sandbox here, and
    # a non-root builder could not set the bit anyway.
    test -x "$P/opt/brave.com/brave/chrome-sandbox"
    test ! -u "$P/opt/brave.com/brave/chrome-sandbox"

    # Executables need the store interpreter too. chrome_crashpad_handler and chrome-sandbox
    # ship pointing at /lib64/ld-linux-x86-64.so.2, which is a host symlink, not a store path.
    for b in brave chrome_crashpad_handler chrome-sandbox; do
      interp=$(patchelf --print-interpreter "$P/opt/brave.com/brave/$b")
      case "$interp" in
      /nix/store/*) ;;
      *) echo "no store interpreter on $b: $interp"; exit 1 ;;
      esac
    done

    # The rpath is the library list the derivation declares, not the copied ELF's own.
    for f in "$P"/opt/brave.com/brave/*.so*; do
      rpath=$(patchelf --print-rpath "$f")
      case "$rpath" in
      *gtk+3*) ;;
      *) echo "rpath not rewritten on $(basename "$f"): $rpath"; exit 1 ;;
      esac
    done

    # The launcher's shebang has to point at a store bash: /bin/bash is a host symlink.
    head -1 "$P/opt/brave.com/brave/brave-browser" | grep -q '^#!\(/nix/store/\|/usr/bin/env /nix/store/\)'

    # Flags reach both entry points and stay verbatim: escaped into makeWrapper, not expanded
    # by the build shell.
    for w in "$W/bin/brave" "$W/bin/brave-browser"; do
      grep -qa -- '--password-store=basic' "$w"
      grep -qa -- '--flag=$(id)' "$w"
    done

    # Desktop entries move into share/ and lose the rpm's absolute Exec, which points at a
    # path nothing in the store has.
    test -e "$P/share/applications/com.brave.Browser.desktop"
    test -e "$P/share/applications/brave-browser.desktop"
    grep -q '^Exec=brave-browser$' "$P/share/applications/com.brave.Browser.desktop"
    grep -q '^Exec=brave-browser$' "$P/share/applications/brave-browser.desktop"
    grep -qv '/usr/bin/' "$P/share/applications/brave-browser.desktop"

    # The icon is installed where the desktop search paths look, and the deb's usr/ is gone.
    test -e "$P/share/icons/hicolor/128x128/apps/brave-browser.png"
    test ! -e "$P/usr"

    mkdir -p $out
  ''
