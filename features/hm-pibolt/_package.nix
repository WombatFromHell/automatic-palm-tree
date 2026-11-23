{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  pinMeta,
}: let
  # Mutable pin metadata, written by ./update.sh. `version` is the release tag itself
  # ("bolt-v1.3.0"): the tag is what the download URL names, and update.sh writes back exactly the
  # tag it found. The repo also publishes android-v*/ios-v* releases, so metadata.json's `channel`
  # filter keeps strategy "latest" on the desktop tags.
  pin = lib.importJSON ./metadata.json;

  # Release asset URL + hash come from the shared pin contract
  asset = pinMeta.releaseAsset pin stdenv.hostPlatform.system;
in
  # Upstream ships a prebuilt bun single-file executable, so nothing here compiles. The tarball is
  # one directory holding `pi`, `pi-start` and the resources `pi` resolves beside itself —
  # package.json (its version stamp: pi prints 0.0.0 when it cannot read it), theme/, assets/,
  # docs/ and native/*.node. The whole tree therefore goes to libexec/ together, and bin/ only
  # links into it.
  #
  # Upstream publishes SHA256SUMS plus a signature, not a per-asset `<asset>.sha256`, so
  # lib/updater.sh finds no sidecar here and keeps the hash it prefetched at pin time.
  # shortcut: to verify against upstream's SHA256SUMS.sig, teach lib/updater.sh a manifest-shaped
  # checksum file; upgrade when a release is ever tampered with.
  stdenv.mkDerivation (finalAttrs: {
    pname = "pi-bolt-bin";
    # metadata.json carries the release tag, which is what the download URL names. The store path
    # wants the version the tag carries, not its channel prefix: pi-bolt-bin-v1.3.0, not
    # pi-bolt-bin-bolt-v1.3.0.
    version = lib.removePrefix "bolt-" pin.version;

    src = fetchurl asset;

    nativeBuildInputs = [patchelf];
    # Prebuilt binaries carry their own symbols and BuildID; strip has nothing to gain here.
    dontStrip = true;
    # Unpack in $PWD rather than through stdenv's default hook: that one cd's into the extracted
    # directory and sets a relative sourceRoot, and the installPhase below moves that directory
    # wholesale.
    unpackPhase = ''
      tar xJf "$src"
    '';

    installPhase = ''
      runHook preInstall

      # Upstream names the directory after the asset it came from, so the arch token is in it.
      dir="$(find . -maxdepth 1 -type d -name 'pi-bolt-linux-*' -print -quit)"
      mkdir -p $out/bin $out/libexec
      mv "$dir" $out/libexec/pi-bolt

      # docs/ and examples/ are upstream source-tree extras; pi resolves its resources (theme/,
      # assets/, native/) beside itself and never reads them.
      rm -rf "$out/libexec/pi-bolt/docs" "$out/libexec/pi-bolt/examples"
      # `pi` is dynamically linked against the host's glibc (/lib64); `pi-start` is statically
      # linked, so only pi needs rewriting into the store.
      linker="$(cat $NIX_CC/nix-support/dynamic-linker)"
      patchelf --set-interpreter "$linker" \
        --set-rpath "${lib.makeLibraryPath [stdenv.cc.libc]}" \
        "$out/libexec/pi-bolt/pi"

      ln -s ../libexec/pi-bolt/pi $out/bin/pi
      ln -s ../libexec/pi-bolt/pi-start $out/bin/pi-start

      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      # The rewritten interpreter is what makes a store-path binary run at all, and 0.0.0 is what
      # pi prints when package.json is not beside the executable it resolved.
      # pi opens a trust lock under $HOME at startup, and the build sandbox has no writable one.
      export HOME="$TMPDIR"
      ver="$($out/bin/pi --version)"
      case "$ver" in
        0.0.0*)
          echo "pi did not read package.json next to the binary: $ver" >&2
          exit 1
          ;;
      esac
      echo "$ver" | grep -q 'Pi-Bolt'
      $out/bin/pi-start --help | grep -q 'pi-bolt'

      runHook postInstallCheck
    '';

    meta = {
      description = "Pi-Bolt — the Pi coding agent as a prebuilt release binary, with bundled extensions and phone remote control";
      homepage = "https://github.com/opensec-git/Pi-Bolt";
      changelog = "https://github.com/opensec-git/Pi-Bolt/releases/tag/${pin.version}";
      license = lib.licenses.mit;
      mainProgram = "pi";
      platforms = pinMeta.pinnedSystems pin;
    };
  })
