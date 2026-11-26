{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs-slim_24,
  curl,
  pinMeta,
}: let
  # Mutable pin metadata, written by ./update.sh. `version` is the commit behind the release tag
  # (pi-web's tags are v-prefixed and updater.sh strips the leading v, so a latest pin would name a
  # revision GitHub's archive endpoint cannot serve): strategy "none" pins the commit, like hm-dsh.
  pin = lib.importJSON ./metadata.json;

  # Nar of the pinned commit, not a git clone: pi-web builds from files, and nar keeps fetches cheap.
  src = fetchFromGitHub (pinMeta.gitSource pin stdenv.hostPlatform.system);
in
  buildNpmPackage (finalAttrs: {
    pname = "pi-web";
    inherit (pin) version;

    inherit src;

    # Hash of the npm dependency cache prefetch-npm-deps builds from the pinned package-lock.json.
    # updater.sh clears depsHashes when the pin moves, because the closure changes with it.
    npmDepsHash = pinMeta.depsHash pin stdenv.hostPlatform.system;

    # Upstream's `build` is the whole pipeline: generate:material-icons (prebuild), tsc, the bin
    # launchers, the plugin API, the plugins, and the vite client bundle.
    npmBuildScript = "build";

    # Upstream's suite is vitest plus playwright browser tests; the tagged commit is what upstream
    # CI already verified. shortcut: unchecked; upgrade by setting doCheck = true if the suite ever
    # runs headless.
    doCheck = false;

    # stdenv would re-patch the shebangs the installPhase rewrites below, back to the build-time
    # node, and walking 743MB of node_modules to do it costs minutes.
    dontPatchShebangs = true;

    # The fetch-time npm cache must never leak into $out. The copy below shares inodes with it,
    # which is not a reference, so this stays green; it fails if a file ever names the cache path.
    disallowedReferences = [finalAttrs.npmDeps];

    # Build-time tools only: nodejs (full), corepack and npm are build inputs of buildNpmPackage and
    # stay out of the runtime closure; curl is here for the install check's /health poll.
    nativeBuildInputs = [curl];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/libexec/pi-web $out/bin
      # dist/ is everything compiled (cli.js, server/, client/, pi-web-plugins/, runtimePreflight.js);
      # node_modules is the runtime tree, and the Pi SDK it carries is what pi-web resolves.
      # No prune: the SDK imports typebox, which pi-web declares only as a devDependency.
      cp -R dist node_modules package.json LICENSE docs extensions $out/libexec/pi-web/

      # npm's hooks patch node_modules shebangs to store binaries — the build-time node, bash and
      # python — which would drag all of them into the runtime closure. Non-node ones go back to
      # /usr/bin/env; node ones point at the runtime node this package ships.
      grep -rlIE '^#!/nix/store/[^/]*/bin/[^ ]+$' $out/libexec/pi-web | xargs -r sed -i -E '1s|^#!/nix/store/[^/]*/bin/([^ ]+)$|#!/usr/bin/env \1|'
      grep -rlIE '^#! */usr/bin/env node$' $out/libexec/pi-web | xargs -r sed -i -E "1s|^#! */usr/bin/env node$|#!${nodejs-slim_24}/bin/node|"

      # node-gyp's build metadata embeds absolute store paths — python3, nodejs headers, the npm
      # cache — which would land in the runtime closure. build/Release/pty.node is what node-pty loads.
      find "$out/libexec/pi-web/node_modules" -type f "(" -name config.gypi -o -name '*.target.mk' -o -name '*.Makefile' ")" -delete
      rm -f "$out/libexec/pi-web/node_modules/node-pty/build/Makefile"

      # The generated launchers look for node in /usr/bin et al. and on PATH; nothing here is in the
      # store, so point the node candidates at the runtime Node instead of putting node on PATH: the
      # systemd units pi-web installs run the launcher with the unit's PATH, where a wrapper's
      # prefix would not apply.
      sed -i "s#/usr/bin/node /usr/local/bin/node /opt/homebrew/bin/node#${nodejs-slim_24}/bin/node#" \
        $out/libexec/pi-web/dist/bin/*.sh
      grep -q "${nodejs-slim_24}/bin/node" $out/libexec/pi-web/dist/bin/pi-web.sh

      # $0 resolves through the symlink chain to the launcher itself, so bin/ links rather than wraps.
      ln -s ../libexec/pi-web/dist/bin/pi-web.sh $out/bin/pi-web
      ln -s ../libexec/pi-web/dist/bin/pi-web-server.sh $out/bin/pi-web-server
      ln -s ../libexec/pi-web/dist/bin/pi-web-sessiond.sh $out/bin/pi-web-sessiond

      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      export HOME=$TMPDIR
      # --version is the launcher's own dispatch, and --check-runtime loads the terminal plugin's pty
      # provider: the only thing that proves node-pty's compiled binding survives the metadata delete.
      $out/bin/pi-web --version | grep -q '^1\.'
      $out/bin/pi-web --check-runtime
      # pi-web resolves the Pi SDK by walking up from import.meta.resolve() to a package.json named
      # @earendil-works/pi-coding-agent, so that root must exist next to dist/.
      test -f $out/libexec/pi-web/node_modules/@earendil-works/pi-coding-agent/package.json
      # The runtime the launchers resolved, then a real boot: --dev keeps it out of the service
      # manager and the real workspace, and /health is what the server reports when it is up.
      $out/bin/pi-web-server --print-runtime | grep -q '^node$'
      mkdir -p "$TMPDIR/pi-web-check/home" "$TMPDIR/pi-web-check/devroot"
      HOME="$TMPDIR/pi-web-check/home" PI_WEB_PORT=18098 PI_WEB_DEV_ROOT="$TMPDIR/pi-web-check/devroot" \
        timeout 60 "$out/bin/pi-web-server" --dev --no-service-manager >"$TMPDIR/pi-web-check/server.log" 2>&1 &
      pid=$!
      deadline=$((SECONDS + 45))
      while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -sf --max-time 3 "http://localhost:18098/health" >"$TMPDIR/pi-web-check/health.json"; then
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          exit 0
        fi
        sleep 1
      done
      kill "$pid" 2>/dev/null || true
      echo "pi-web dev server never reported /health:"
      cat "$TMPDIR/pi-web-check/server.log"
      exit 1
    '';

    # No changelog URL: `version` is a commit, and releases/tag/ names tags.
    meta = {
      description = "Web UI for persistent Pi coding-agent sessions in real workspaces";
      homepage = "https://pi-web.dev/";
      license = lib.licenses.mit;
      mainProgram = "pi-web";
      platforms = pinMeta.pinnedSystems pin;
    };
  })
