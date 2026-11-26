---
id: ADR-f52f9a9add4c
type: adr
slug: hm-piweb-builds-pi-web-from-the-pinned-commit-an
title: hm-piweb builds pi-web from the pinned commit and keeps build-time Node, npm and python out of its runtime closure
created: 2026-11-26T03:39:46Z
author: josh@methyl-bazzite
status: accepted
scope:
  - features/hm-piweb/_package.nix
  - features/hm-piweb/home.nix
  - features/hm-piweb/metadata.json
  - features/hm-piweb/update.sh
  - tests/piweb.nix
constraint: |
  features/hm-piweb builds pi-web from the commit pinned in metadata.json through buildNpmPackage, ships dist/ and node_modules at $out/libexec/pi-web with $out/bin holding symlinks into it, keeps build-time Node, npm and python out of the runtime closure by rewriting shebangs to /usr/bin/env and to nodejs-slim_24 with dontPatchShebangs = true and deleting node-gyp's build metadata, proves the install by booting the dev server against /health, and reaches PATH through home.packages rather than running pi-web install.
enforced_by:
  - features/hm-piweb/_package.nix#installPhase
  - features/hm-piweb/_package.nix#installCheckPhase
  - tests/piweb.nix#testPiWebIsNamedForItsPin
  - tests/piweb.nix#testPiWebInstallsChecked
  - tests/piweb.nix#testPiWebNamesItsProgramAndPin
  - tests/piweb.nix#testPiWebRunsOnTheSharedSlimNode
  - tests/pins.nix#testEveryUpdateShIsTheSharedSymlink
ratified: c230ee5384b4
anchor: 7a2fd2ad83405c853872c22d0b62e10a4275ee6a
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-26T03:41:17Z
schema: 4
version: 2
---

pi-web publishes `v*` tags, but `version` holds the commit behind the tag and not the tag:
`lib/updater.sh` strips a leading `v`, and GitHub's archive endpoint serves a rev rather than a tag
name (ADR-0b73, ADR-ba1f), so a `latest` pin would name something the URL cannot fetch.
`kind = "nar"` and `strategy = "none"` pin it the way hm-ank and hm-dsh do (ADR-0b73, ADR-8b56):
the build reads files, not git history, and a nar keeps the fetch cheap. `hashes` is the source nar;
`depsHashes` is the `fetchNpmDeps` cache `buildNpmPackage` consumes as `npmDepsHash`, and the updater
clears it when the pin moves because `package-lock.json` changes with the commit.
`pinMeta.gitSource`, `pinMeta.depsHash` and `pinMeta.pinnedSystems` are the only readers, and
`meta.platforms` is `pinMeta.pinnedSystems pin`: one system, `x86_64-linux`, as every host here runs.

`npmBuildScript = "build"` is the whole upstream pipeline - generate:material-icons as prebuild, tsc,
the bin launchers, the plugin API, the plugins and the vite client bundle. Running tsc alone yields a
tree whose launchers and plugin bundles do not exist. The layout is the decision: `dist/`,
`node_modules`, `package.json`, `LICENSE`, `docs` and `extensions` move to `$out/libexec/pi-web`, and
`$out/bin` holds three symlinks into `dist/bin/*.sh` rather than wrappers, because `$0` resolves
through the symlink chain to the launcher itself. `package.json` must sit beside `dist/`: pi-web
resolves the Pi SDK by walking up from `import.meta.resolve()` to a package.json named
`@earendil-works/pi-coding-agent`. There is no `npm prune` - the SDK imports `typebox`, which pi-web
declares only as a devDependency, so pruning removes a module the runtime needs. The tree is about
850MB, roughly 770MB of it `node_modules`; that is the price of shipping the SDK rather than
installing it.

The runtime closure is the part that is otherwise wrong. npm's hooks patch shebangs inside
`node_modules` to build-time store binaries - the full `nodejs`, `bash` and `python3` - and each one
becomes a runtime reference, so the naive build carried all three plus `corepack`, `npm` and the
Node source. So `dontPatchShebangs = true` stops stdenv patching them back after the install phase,
and the install phase rewrites them itself: non-node shebangs go back to `/usr/bin/env <name>`, and
node ones point at `nodejs-slim_24/bin/node`, the shared runtime Node every host already carries.
node-gyp's build metadata (`config.gypi`, `*.target.mk`, `node-pty`'s `build/Makefile`) embeds
absolute store paths for python3, nodejs headers and the npm cache, so those files are deleted;
`build/Release/pty.node` is what node-pty actually loads. `disallowedReferences =
[finalAttrs.npmDeps]` states that the fetch-time npm cache must never leak into `$out` - the copy
shares inodes with it, which is not a reference, so the check stays green and fails only if a file
ever names the cache path. `nativeBuildInputs` adds only `curl`, for the health poll. What the host
then carries is pi-web's tree plus `nodejs-slim_24` and whatever Node pulls for itself; bash and
coreutils arrive through Node's own closure, and no file in `$out` names their store paths.

The launchers are rewritten rather than wrapped. Upstream's generated `dist/bin/*.sh` look for node in
`/usr/bin`, `/usr/local/bin` and `/opt/homebrew/bin` and then on PATH; a wrapper putting Node on PATH
would not apply when pi-web's own systemd user units run a launcher under the unit's PATH, so the
candidate list is rewritten to the shipped slim node and the install phase asserts the rewrite landed.

`doInstallCheck` is the proof the package runs, and it is a real boot rather than a listing:
`pi-web --version` exercises the launcher's own dispatch, `pi-web --check-runtime` loads the terminal
plugin's pty provider (the only thing proving `pty.node` survived the metadata delete), the SDK's
package.json must exist beside `dist/`, and `pi-web-server --print-runtime` must name `node`. Then
`pi-web-server --dev --no-service-manager` is started with an isolated `HOME` and `PI_WEB_DEV_ROOT` on
a throwaway port and polled on `/health`. `--dev --no-service-manager` is what keeps that check out of
the real workspace and out of the service manager. `doCheck = false`: upstream's suite is vitest plus
playwright browser tests, and the pinned commit is what upstream CI already verified; the shortcut is
recorded in the derivation and upgrades by setting `doCheck = true` if the suite ever runs headless.

`features/hm-piweb/home.nix` is opt-in through the host feature list, discovered by name like every
other feature (ADR-f704), and puts one package in `home.packages`. Home Manager declares no
`programs.pi-web`, and a program module would name one binary while hiding `pi-web-server` and
`pi-web-sessiond`; `meta.mainProgram = "pi-web"` says which of the three is the program. The package
reaches PATH through `callPackage` in the package set, not an overlay (ADR-380b). Upstream's
`pi-web install` and `pi-web update` are not used: `install` writes systemd user units into
`~/.config/systemd` from a launcher outside the store, and `update` runs `npm install -g` - the same
rule ADR-033d states for cargo. The store tree is the installation, and
`features/hm-piweb/update.sh`, the `lib/updater.sh` symlink whose URL expansion is byte-compared with
`lib/pin-meta.nix` by the gate (ADR-122a, ADR-ba1f), is what moves it.

Two limits recorded rather than fixed. The install check never exercises the systemd user units pi-web
installs, because it runs `--no-service-manager`: the launcher rewrite means those units would resolve
Node, but their unit files are not asserted here. And nothing here supervises or deletes them - a host
that runs `pi-web install` anyway gets units pointing at this store path.

Consequences: coverage is eval-side (`tests/piweb.nix`, four nix-unit attributes that force `drvAttrs`
keys only, no build and no npm fetch, floored in `tests/suite-ledger.txt`), pin-side through the
discovery and expander parity checks that already cover every feature with a metadata.json, and
build-side through `installCheckPhase`, which is where the boot proof actually runs. A host that lists
`hm-piweb` carries about 3.2GB of runtime closure. `hosts/methyl-bazzite.nix` lists it today and no
other host does.
