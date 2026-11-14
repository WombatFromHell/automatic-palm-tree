{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  makeBinaryWrapper,
  nodejs_24,
  pnpm_11,
  pnpmBuildHook,
  pnpmConfigHook,
  pinMeta,
}: let
  # Mutable pin metadata, updated by ./update.sh. `version` is the commit behind the latest
  # release tag (all tags are prerelease, so nothing auto-discovers it): the archive behind
  # it cannot move, and the pin moves explicitly via ./update.sh <commit>.
  pin = lib.importJSON ./metadata.json;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "deepseek-harness";
    inherit (pin) version;
    strictDeps = true;
    __structuredAttrs = true;
    # The baseline pins rc.1 from git with leaveDotGit and stamps the commit in postFetch;
    # the pinned tarball has no .git, so the fetcher's rev is the commit itself.
    src = fetchFromGitHub (pinMeta.gitSource pin stdenv.hostPlatform.system);
    # internalModules() calls node-addon-require-builtin unconditionally, but
    # its binary scan does not recognize toolchain-built Node
    # (Unsupported/no-getter), breaking every `dsh --profile …` boot. Prefer a
    # plain require under --expose-internals (which the wrapper below passes).
    patches = [./expose-internals-profile-resolution.patch];
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pnpm_11;
      fetcherVersion = 4;
      # Closure of the pinned rc.3 pnpm-lock.yaml (not the rc.1-era baseline hash — rc.3 moved
      # e.g. the zod peer 4.4.3 -> 4.6.6); computed via the fetcher's hash="" mismatch probe.
      hash = "sha256-md84fDBaEnqdQxlsTpaGTkGWWH1dLUGwlSp0EJ+aOA4=";
    };
    nativeBuildInputs = [nodejs_24 pnpmConfigHook pnpmBuildHook pnpm_11 makeBinaryWrapper];
    # The tarball has no .git-commit marker: the stamp is the pinned rev, static at eval time.
    preBuild = ''
      export DSH_CLIENT_COMMIT_HASH="${pin.version}"
      export DSH_CLIENT_BUILD_PROFILE="official";
    '';
    # The root 'build' script runs both 'build:lib' and 'build:web'
    # pnpmBuildHook runs 'pnpm run build' by default
    installPhase = ''
      runHook preInstall
      mkdir -p $out/libexec/dsh
      cp -r . $out/libexec/dsh/
      # Drop dangling symlinks from optional cross-platform packages.
      find $out/libexec/dsh/node_modules/.pnpm -type l ! -exec test -e {} \; -delete
      # Mirror workspace packages to the root node_modules so the loader's bare import() resolves.
      shopt -s nullglob
      store_scopes=("$out/libexec/dsh/node_modules/.pnpm/node_modules/"@*/)
      for scope in "''${store_scopes[@]}"; do
        scope_name=$(basename "$scope")
        mkdir -p "$out/libexec/dsh/node_modules/$scope_name"
        for pkg in "$scope"*; do
          # -n: do not dereference an existing symlink-to-dir
          ln -sfn "../.pnpm/node_modules/$scope_name/$(basename "$pkg")" \
            "$out/libexec/dsh/node_modules/$scope_name/$(basename "$pkg")"
        done
      done
      # --expose-internals is required by the HMR service and the loader's internal module loader
      makeBinaryWrapper ${nodejs_24}/bin/node $out/bin/dsh \
        --prefix PATH : ${lib.makeBinPath [pnpm_11]} \
        --add-flags "--expose-internals $out/libexec/dsh/apps/cli/lib/bin.js"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      export HOME=$TMPDIR
      $out/bin/dsh --version
    '';
    meta = {
      description = "AI agent harness with a plugin-based architecture";
      longDescription = ''
        DeepSeek Harness (dsh) is a self-hosted AI agent harness built around a plugin
        architecture — "Everything is a Plugin". It ships a CLI and a web UI and is
        extended through workspace plugins.
      '';
      homepage = "https://github.com/deepseek-ai/deepseek-harness";
      license = lib.licenses.mit;
      mainProgram = "dsh";
      platforms = pinMeta.pinnedSystems pin;
    };
  })
