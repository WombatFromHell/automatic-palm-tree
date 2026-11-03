#!/usr/bin/env nix
# nix build --no-link -f tests/yazi-install.nix
# What features/hm-yazi/_package.nix puts in its $out is not an evaluated value, so this re-runs
# its real postInstall against the real pinned tree: the unpacked fork archive plus the man-page
# repo, with buildPhase and installPhase replaced and every Rust input dropped. Nothing compiles
# and no crate is fetched — only the two pinned sources are unpacked (~15 MB, cached in the store).
#
# That is the point: the assertion is about the revision we pinned, not about a tree we drew. If
# a bump moves a completion out of assets/completions/ or drops the desktop entry, this fails
# here instead of in a user's home. tests/run.sh reads the build's exit status.
let
  s = import ./support.nix;
  inherit (s) pkgs;

  package = pkgs.callPackage ../features/hm-yazi/_package.nix {};

  # A plain stdenv over the real derivation's source tree and postInstall: no rust, no cargo
  # setup hook, so no crate is fetched and nothing compiles.
  fixture = pkgs.unstable.stdenv.mkDerivation {
    pname = "yazi-install-fixture";
    inherit (package) version srcs sourceRoot postInstall;
    nativeBuildInputs = [pkgs.unstable.installShellFiles pkgs.unstable.imagemagick];
    buildPhase = ''
      echo "fixture: no compile"
    '';
    installPhase = ''
      mkdir -p $out/bin
    '';
    # postInstall already ran (stdenv runs the hook around installPhase); this only checks $out.
    postPhase = ''
      # installShellCompletion --cmd renames by command, so the shipped names are what count.
      for f in share/bash-completion/completions/yazi.bash share/bash-completion/completions/ya.bash \
               share/fish/vendor_completions.d/yazi.fish share/fish/vendor_completions.d/ya.fish \
               share/zsh/site-functions/_yazi share/zsh/site-functions/_ya \
               share/man/man1/yazi.1 share/man/man5/yazi-config.5 \
               share/applications/yazi.desktop; do
        [ -e "$out/$f" ] || { echo "missing: $f" >&2; exit 1; }
      done

      # The logo resize loop is the part most likely to break on a fork revision.
      for RES in 16 24 32 48 64 128 256; do
        [ -s "$out/share/icons/hicolor/$RES"x"$RES"/apps/yazi.png" ] || {
          echo "missing logo: $RES" >&2
          exit 1
        }
      done

      # A completion that names the wrong command ships a broken shell.
      grep -q _yazi "$out/share/zsh/site-functions/_yazi"
      grep -q ya "$out/share/fish/vendor_completions.d/ya.fish"
    '';
  };
in
  fixture
