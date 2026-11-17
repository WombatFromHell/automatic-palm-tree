{
  lib,
  stdenv,
  curl,
  fetchFromGitHub,
  fetchPnpmDeps,
  makeBinaryWrapper,
  nodejs_24,
  nodejs-slim_24,
  pnpm_11,
  pnpmBuildHook,
  pnpmConfigHook,
  runCommand,
  pinMeta,
}: let
  # Mutable pin written by ./update.sh. `version` is the commit behind the release tag (every tag
  # is prerelease, so nothing auto-discovers it): it is the archive rev and the commit stamp the
  # client build embeds, and update.sh moves it only when someone passes <ref>.
  pin = lib.importJSON ./metadata.json;

  # Closure-size toggles. Flip one at a time and re-run the tests to bisect a regression.
  trimSourceMaps = true; # leave *.map files out of $out
  # Everything the web profile ships: the CLI and its plugin packages. Left out are the desktop
  # carriers (Electron), the test carriers, ssh/lsp plugins, and repo-only docs and tooling. A
  # wrongly listed dir fails the web-boot test, not the build, so bisect with an empty list.
  trimDirs = [
    ".agents"
    "apps/desktop"
    "apps/desktop-host"
    "apps/desktop-publisher"
    "apps/plugin-market-generator"
    "benchmarks"
    "docs"
    "packages/host/authentication-desktop"
    "packages/lsp"
    "packages/ssh"
    "packages/test-support"
    "patches"
    "python"
    "scripts"
    "snapshots"
    "website"
  ];
  # Nested dirs the runtime never reads: tests and TypeScript sources. Compiled code lives in
  # lib/, and nothing in lib/ imports a `/src/*` specifier (only tests do), so both are dead
  # weight. Empty the list to bisect a regression.
  trimNested = [
    "packages/*/*/tests"
    "packages/*/*/src"
    "apps/*/tests"
    "apps/*/src"
  ];
  # Delete .pnpm entries outside apps/cli's production graph: devDependencies (typescript, vitest,
  # tsdown, oxlint, electron) and the plugins the web profile never mounts (@openai/codex, the
  # Claude agent SDK, chrome-devtools-frontend, cua-driver, sherpa-onnx).
  reachabilityPrune = true;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "deepseek-harness";
    inherit (pin) version;
    src = fetchFromGitHub (pinMeta.gitSource pin stdenv.hostPlatform.system);

    # Our fork fix: internalModules() calls node-addon-require-builtin, whose binary scan does not
    # recognize toolchain-built Node, so every `dsh --profile …` boot fails. patchPhase runs before
    # the build, so this lands on the source resolver.ts rather than on the built output.
    patches = [./expose-internals-profile-resolution.patch];

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pnpm_11;
      fetcherVersion = 4;
      hash = pinMeta.depsHash pin stdenv.hostPlatform.system;
    };

    # pnpm's hooks read their flag arrays through concatTo, which stdenv only defines under
    # structuredAttrs.
    __structuredAttrs = true;
    strictDeps = true;

    # Build-time tools only. pnpm_11 and the full nodejs_24 stay out of the runtime closure:
    # the wrappers below reference nodejs-slim_24 and the pnpm shipped inside node_modules.
    nativeBuildInputs = [nodejs_24 pnpmConfigHook pnpmBuildHook pnpm_11 makeBinaryWrapper];

    # The fetch-time pnpm store must never leak into $out. Under structuredAttrs nixpkgs maps this
    # into outputChecks; verify it still fails the build on your revision by temporarily
    # referencing the store path from installPhase.
    disallowedReferences = [finalAttrs.pnpmDeps];

    # Upstream's `build` chains build:check — the repository-wide gates upstream CI already ran on
    # this tagged commit — onto the artifacts. A release build needs the artifacts only.
    pnpmBuildScript = "build:artifacts";

    # Client build stamp, read by scripts/build.ts from the environment. The pinned tarball carries
    # no .git, so the commit comes from the pin instead of a postFetch marker; structuredAttrs puts
    # attrs in the build shell as variables, and pnpm's child process only sees exported ones.
    preBuild = ''
      export DSH_CLIENT_COMMIT_HASH="${pin.version}"
      export DSH_CLIENT_BUILD_PROFILE="official"
    '';

    # $out/libexec holds the whole pnpm tree, tens of thousands of files. Strip only the wrapper;
    # skip patchelf and shebang patching, since the native addon carries its own runpath and nothing
    # in a release build runs a `#!/usr/bin/env node` script. Walking that tree costs minutes.
    # shortcut: if dsh fails to load a native addon, drop dontPatchELF first.
    stripDebugList = ["bin"];
    dontPatchELF = true;
    dontPatchShebangs = true;

    installPhase = ''
      runHook preInstall

      ${lib.optionalString reachabilityPrune ''
        # The shipped program is apps/cli, so its production dependency graph is what `dsh` loads.
        # Workspace plugins are workspace symlinks, not .pnpm entries, so they survive untouched:
        # only third-party packages are pruned. The pinned checkout holds 1435 entries (2.1G);
        # this graph keeps 422 of them (620M).
        pnpm --filter ./apps/cli list --prod --depth Infinity --parseable \
          | sed -n 's#.*/node_modules/\.pnpm/\([^/]*\)/node_modules/.*#\1#p' | sort -u > keep.txt
        # dsh shells out to the pnpm shipped in node_modules, so it must survive the prune. It
        # declares no dependencies of its own, so its entry alone is its whole closure.
        ls node_modules/.pnpm | grep -E '^pnpm@' >> keep.txt
        # Dev-only third-party tools still reach apps/cli's graph because pnpm's --prod list
        # follows peerDependencies: lint plugins, the test runner, DOM emulation, type-only
        # packages, and the ONNX voice runtime whose carrier dir is trimmed above. Nothing in
        # lib/ or apps/web/dist loads them, and web-boot is the proof.
        grep -vE '^(eslint|jsdom|vitest|@vitest|vite|esbuild|oxlint|@types|sherpa-onnx)' keep.txt > keep-only.txt && mv keep-only.txt keep.txt
        for d in node_modules/.pnpm/*/; do
          n=$(basename "$d")
          [ "$n" = node_modules ] && continue
          grep -qxF "$n" keep.txt || rm -rf "$d"
        done
      ''}

      mkdir -p $out/libexec/dsh
      # Copy the tree minus VCS metadata, tool caches and (optionally) maps and unused repo dirs.
      tar -cf - \
        --anchored --no-wildcards-match-slash \
        --exclude=./.git --exclude=./.github --exclude=./.turbo --exclude=./.vite --exclude=./.cache \
        ${lib.optionalString trimSourceMaps "--exclude='*.map'"} \
        ${lib.concatMapStringsSep " " (d: "--exclude=./${d}") trimDirs} \
        ${lib.concatMapStringsSep " " (d: "--exclude='./${d}'") trimNested} \
        . | tar -xf - --no-same-owner -C $out/libexec/dsh

      # Pruning leaves symlinks in the workspace packages' own node_modules pointing at deleted
      # store entries, which Node reports as ERR_MODULE_NOT_FOUND. -xtype l matches links with
      # missing targets in one pass, repo-wide, without forking `test` per link.
      find $out/libexec/dsh -xtype l -printf '%p -> %l\n' \
        | grep -E -- '-> .*(packages|apps|vendor)/' | sort | tee dangling-workspace.txt
      find $out/libexec/dsh -xtype l -delete

      # pnpm keeps workspace packages only inside .pnpm/node_modules; bare import() of them needs a
      # root node_modules entry.
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

      # dsh shells out to pnpm at runtime. Use the exact version upstream pins (it is a root
      # devDependency, so already in node_modules) on the slim Node, instead of shipping nixpkgs'
      # pnpm_11 and the Node it wraps.
      pnpm_entry="$out/libexec/dsh/node_modules/pnpm/bin/pnpm.cjs"
      test -f "$pnpm_entry" || { echo "pnpm entry point not found: $pnpm_entry" >&2; exit 1; }
      mkdir -p $out/libexec/dsh/bin
      makeBinaryWrapper ${nodejs-slim_24}/bin/node $out/libexec/dsh/bin/pnpm \
        --add-flags "$pnpm_entry"

      # --expose-internals is required by the HMR service and the loader's internal module loader.
      # node is not on PATH: bin.js is started by node directly, and only pnpm is ever invoked.
      makeBinaryWrapper ${nodejs-slim_24}/bin/node $out/bin/dsh \
        --prefix PATH : $out/libexec/dsh/bin \
        --add-flags "--expose-internals $out/libexec/dsh/apps/cli/lib/bin.js"

      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      export HOME=$TMPDIR
      $out/bin/dsh --version
      # The bundled pnpm wrapper must start; --version alone never exercises the pnpm call.
      (cd $TMPDIR && $out/libexec/dsh/bin/pnpm --version)
    '';

    # The web profile is the boot path the patch exists for, and the only place a workspace
    # package's runtime dependencies are exercised: a broken dependency tree still passes --version.
    passthru.tests.web-boot =
      runCommand "deepseek-harness-web-boot"
      {
        nativeBuildInputs = [
          curl
          finalAttrs.finalPackage
        ];
      }
      ''
        export HOME=$TMPDIR
        dsh --profile web --no-open --port 0 >server.log 2>&1 &
        pid=$!
        trap 'kill $pid 2>/dev/null || true' EXIT
        for i in $(seq 1 30); do
          if launch_url=$(grep -o 'http://127.0.0.1:[0-9]\+/?token=[^[:space:]]*' server.log); then
            break
          fi
          sleep 1
        done
        if [ -z "''${launch_url:-}" ]; then
          echo "dsh web profile failed to print the authenticated launch URL" >&2
          cat server.log >&2
          exit 1
        fi
        if grep -qE 'did not activate|ERR_MODULE_NOT_FOUND' server.log; then
          echo "dsh web profile reported a plugin that did not activate" >&2
          cat server.log >&2
          exit 1
        fi
        echo "✓ Found launch URL on server logs ($launch_url)"
        curl --fail --silent --show-error --location -c cookies.txt "$launch_url" | grep -q '<!doctype html>'
        touch $out
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
