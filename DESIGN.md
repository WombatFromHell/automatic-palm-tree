# DESIGN — Architecture

Plain flake (no flake-parts). Everything the flake exposes is produced by `./lib`, which is
split by concern: discovery, validation, package sets, and config builders. Hosts and features
are data; the loader is the only place that knows how they combine.

## Layout

```
flake.nix          # outputs only: nixosConfigurations, homeConfigurations, checks
lib/               # pure loader, one concern per file
  default.nix      #   composition root: wires the files below, builds one pkgs per host
  host-options.nix #   host record schema (facts / authoring / derived, split by ownership)
  hosts.nix        #   discovery + validation + enrichment
  host-lib.nix     #   host-facing composition: mergeModules, mergeHome, profiles
  features.nix     #   feature discovery + resolveFeaturePaths (unknown feature = throw)
  builders.nix     #   nixosSystem / homeManagerConfiguration, module order
  filesystems.nix  #   mkMounts / mkUnitMounts (subvolume -> mount + automount units;
                   #   automount = true adds the lazy .automount unit, skipIfMissing conditions
                   #   on the device) / joinUnitMounts (concat groups, never //)
  pin-meta.nix     #   metadata.json contract: pinnedSystems, assetHash, releaseAsset, gitSource
  updater.sh       #   generic pin updater; features symlink it to their own update.sh
modules/           # NixOS/HM modules the loader always imports
  cache-registry.nix caches.nix feature-options.nix host-facts.nix nix-settings.nix
  defaults/{nixos,home-manager}.nix packages/pyz-wrapper.nix
features/<name>/   # nixos.nix, home.nix, optional _overlays.nix; private helpers are _*.nix
hosts/             # host records: <name>.nix or <name>/ (nixos.nix + home-<user>.nix)
tests/             # eval-only suite (see TEST_DESIGN.md)
bootstrap.sh       # day-zero switch: cache urls/keys via --option, then switch
update-all.sh      # feature updaters, then flake input bumps
```

39 features: 12 home-only, 18 NixOS-only, 9 with both a `home.nix` and a `nixos.nix`;
2 carry an `_overlays.nix` (`nixos-cachyos`, `nixos-niri`).

## Loader pipeline

```mermaid
flowchart TD
  I["inputs: nixpkgs, nixpkgs-unstable, home-manager, agenix + 9 tool inputs"] --> D["lib/default.nix"]
  D --> HO["host-options.nix<br/>schema: facts + authoring + derived"]
  D --> H["hosts.nix<br/>discover hosts/ → validate → enrich"]
  H --> HD["host records<br/>name, system, isNixOS, users,<br/>features, nixosModules, homeModules<br/>+ derived osUsernames / hmUsernames"]
  D --> F["features.nix<br/>discover features/ → discoveredFeatures"]
  HD --> P["hostsWithPkgs<br/>pkgs + pkgs.unstable + flakePackages + pinMeta"]
  F --> P
  P --> B["builders.nix"]
  B --> NC["nixosConfigurations.&lt;host&gt;"]
  B --> HC["homeConfigurations.&lt;user&gt;@&lt;host&gt;"]
  NC --> O["flake.nix outputs"]
  HC --> O
  O --> C["checks.&lt;system&gt;.nixos-&lt;host&gt; / home-&lt;user&gt;@&lt;host&gt;"]
```

`supportedSystems` is derived from the configurations themselves
(`config.pkgs.stdenv.hostPlatform.system`), so a host targeting a system we do not check cannot
hide behind a missing check.

## Host authoring ergonomics

Host files are records, not modules. They are validated against the schema, so an unsupported
field is an error naming the option, and a derived field cannot be authored.

```mermaid
flowchart LR
  A["&lt;host&gt;.nix<br/>{system, isNixOS, users, features, modules}"] --> V["hostOptions validation"]
  B["&lt;host&gt;/default.nix<br/>+ nixos.nix + home-&lt;user&gt;.nix"] --> V
  V --> M["hostLib<br/>mergeModules: scalars last-wins, lists dedupe by first occurrence<br/>mergeHome: standalone shape, throws on nixos-* features<br/>profiles dir [names]: load and merge"]
  M --> R["enriched host record"]
```

Feature lists are the single source of truth: `features = ["nixos-niri" "hm-tmux"]` resolves to
`features/nixos-niri/nixos.nix` and `features/hm-tmux/home.nix`. A name with no module for the
platform contributes nothing; a name that does not exist throws at evaluation with the available
list.

## NixOS module composition (order matters)

```mermaid
flowchart TD
  1["modules/caches.nix<br/>owns flakeCache: enable, required, ready"] --> 2["resolveFeaturePaths(features, nixos)<br/>+ resolveFeaturePaths(features, overlays)"]
  2 --> 3["modules/feature-options.nix<br/>extraGroups namespace"]
  3 --> 4["modules/host-facts.nix<br/>config.flakeHost"]
  4 --> 5["modules/nix-settings.nix<br/>nix.settings + nix.package"]
  5 --> 6["modules/defaults/nixos.nix<br/>hostName, kernel, users.users, extraGroups"]
  6 --> 7["host.nixosModules<br/>host-local modules, incl. hardware-configuration.nix"]
  7 --> 8["home-manager module<br/>useGlobalPkgs, useUserPackages, users.&lt;user&gt;"]
  8 --> 9["nixpkgs.pkgs = host pkgs"]
```

Caches come first because feature modules gate on `config.flakeCache.enable` — e.g. `nixos-niri`
swaps niri for the spicy build only when its cache is substituted from. Feature overlays are
modules that set `nixpkgs.overlays`, so they are appended to the pinned set at eval time and can
be gated on options; host `pkgs` is threaded in last so a host can pin its own package set.

## Home Manager composition

```mermaid
flowchart LR
  subgraph NixOS["NixOS host"]
    U["home-manager.users.&lt;user&gt;"] --> UM["hostModules + homeModules.&lt;user&gt;"]
  end
  subgraph Standalone["Standalone host"]
    S["homeConfigurations.&lt;user&gt;@&lt;host&gt;"] --> SM["hostModules + targets.genericLinux.enable"]
  end
  UM --> HM["home-manager modules<br/>nixGL wrappers from defaults/home-manager.nix"]
  SM --> HM
```

`useGlobalPkgs` means Home Manager shares the host package set, so gated overlays reach user
packages too; Home Manager modules must not set `nixpkgs.overlays`.

## Cache chain

```mermaid
flowchart LR
  R["modules/cache-registry.nix<br/>url + publicKey per cache"] --> C["modules/caches.nix"]
  C --> S["nix.settings.extra-substituters<br/>extra-trusted-public-keys"]
  C --> W["config.warnings when a required cache<br/>is not enabled"]
  C --> A["assertion: unknown required cache name"]
  R --> B["bootstrap.sh<br/>nix eval --raw → --option<br/>(pre-nixosInstall: root, no config yet)"]
```

## Pin metadata

Three features are metadata-backed today (`hm-brave`, `hm-tmux`, `hm-zed`); each carries a
`metadata.json` and a symlink to `lib/updater.sh` as its own `update.sh`
(`update-all.sh` refuses a copy). The template is expanded twice — once in Nix
(`lib/pin-meta.nix releaseAsset`, at eval) and once in bash (`render_url`, at fetch) —
and `tests/run.sh` diffs the two byte-for-byte for every pin and pinned system.

```mermaid
flowchart LR
  J["features/&lt;name&gt;/metadata.json<br/>repo, version, kind, url, arches, hashes"] --> P["lib/pin-meta.nix<br/>pinnedSystems / assetHash / releaseAsset / gitSource"]
  P --> K["features/&lt;name&gt;/_package.nix<br/>fetchurl or fetchFromGitHub"]
  U["lib/updater.sh"] --> J
  U2["update-all.sh"] --> U
```

`pinMeta` and `flakePackages` are injected into every package set by `lib/default.nix`, so a
feature reads them like a build dependency rather than threading arguments.

## User-facing ergonomics

Currently exposed:

```mermaid
flowchart LR
  E["nix flake check"] --> CK["checks.&lt;system&gt;.*"]
  E2["nix build .#nixosConfigurations.&lt;host&gt;.config.system.build.toplevel"] --> NC["system derivation"]
  E3["nix build .#homeConfigurations.&lt;user&gt;@&lt;host&gt;.activationPackage"] --> HC["HM activation derivation"]
```

Placeholders for ergonomics we do **not** implement yet (no `packages`, `devShell`, or `apps`
output today):

```mermaid
flowchart LR
  X["nix run .#apps.&lt;system&gt;.cache-check &lt;host&gt;<br/>(hypothetical: eval-only cache pre-flight)"] -.->|not implemented| Y["scripts/cache-check.sh"]
  Z["nix devShell (hypothetical: toolchain for updaters)"] -.->|not implemented| W["lib/updater.sh"]
```
