# DESIGN — Architecture & Dependencies

## File Layout

```
flakeroot/
├── flake.nix                       # plain outputs (no flake-parts), imports ./lib
├── lib/                            # pure lib, split by concern
│   ├── default.nix                 #   composition root — re-exports all concern files
│   ├── host-options.nix            #   hostOptions schema
│   ├── features.nix                #   feature discovery + _overlays.nix resolution
│   ├── pin-meta.nix                #   metadata.json pin contract (releaseAsset/gitSource/pinnedSystems, one `pinMeta` member)
│   ├── hosts.nix                   #   host discovery + validation + enrichment
│   └── builders.nix                #   nixosSystem / homeManagerConfiguration builders
├── hosts/                          # per-host declarations (auto-discovered)
│   ├── methyl-bazzite.nix          # HM-only flat host
│   ├── methyl/                     # NixOS host (bare metal)
│   │   ├── default.nix             #   {system,isNixOS,users,features}
│   │   ├── base.nix                #   shared NixOS config (no hw import)
│   │   ├── nixos.nix               #   host wrapper: hw-config + base
│   │   ├── home-josh.nix           #   per-user HM module
│   │   └── hardware-configuration.nix
│   ├── methyl-nixos/               # NixOS host (QEMU VM — reuses methyl/)
│   │   ├── default.nix
│   │   ├── nixos.nix
│   │   ├── home-josh.nix           #   re-imports ../methyl/home-josh.nix
│   │   └── hardware-configuration.nix
│   └── propyl/                     # NixOS host (MacBookPro16,2 / T2 POC — reuses methyl/)
│       ├── default.nix             #   methyl facts + narrowed features (+ nixos-kait2en)
│       ├── base.nix                #   loader/ssh/oomd, authored on top of the hw-config
│       ├── nixos.nix               #   host wrapper: hw-config + base
│       ├── home-josh.nix           #   stub: its own env, methyl's niri/dms options are absent
│       └── hardware-configuration.nix  # placeholder in generated-file shape
├── features/                       # 40 composable units, auto-discovered
│   ├── hm-only    (14)             #   home.nix only
│   ├── nixos-only (18)             #   nixos.nix only
│   ├── hybrid      (8)             #   home.nix + nixos.nix: hm-syncthing, nixos-dmemcg, nixos-dms, nixos-flatpak, nixos-kde, nixos-lsfg, nixos-niri, nixos-oom
│   ├── _overlays.nix               #   optional: {inputs, ...}: [ … ] per feature
│   └── extras                      #   _package.nix / _*.nix / bin/ / *.sh imported by the feature itself
├── modules/
│   ├── bootstrap.nix               # swapfile+zswap for /etc/nixos/swap-prepare.nix (bootstrap.sh)
│   ├── nix-settings.nix            # substituters, trusted keys, nix.package
│   ├── defaults/
│   │   ├── home-manager.nix        # stateVersion, manual off, nixGL wrapMesa default
│   │   └── nixos.nix               # stateVersion, fish, kernel + genAttrs osUsernames → users.users (+ extraGroups)
│   └── packages/
│       └── pyz-wrapper.nix         # generic .pyz fetcher (gamemode, etc.)
├── bootstrap.sh
├── flake.nix / flake.lock
└── DESIGN.md / README.md
```

Feature file convention: `home.nix` → HM platform, `nixos.nix` → NixOS platform. Extras (`_package.nix`, `_*.nix`, `bin/`, `*.sh`) are imported by the feature's own entry point, not discovered.

---

## Module Dependency Graph

Static `imports` vs. runtime `readDir`/`import`.

```mermaid
graph TB
    flake["flake.nix\nplain outputs, no flake-parts\nimports ./lib as function"] --> libDefault["lib/default.nix\ncomposition root:\noverlays → pkgs → config outputs"]

    libDefault --> hostOpts["lib/host-options.nix\nhostOptions schema"]
    libDefault --> featLib["lib/features.nix\ndiscoveredFeatures\nresolveFeaturePaths\nresolveHostOverlays"]
    builders -- "consumed at build time" --> featOpts["modules/feature-options.nix\nfeature enable/disable options"]
    libDefault --> hostsLib["lib/hosts.nix\nparseHostEntry, validateHost\nautoDiscoverModules\nenrichHost, buildHost\ndiscoveredHosts"]
    libDefault --> builders["lib/builders.nix\nbuildNixosConfigurations\nbuildHomeConfigurations"]

    hostsLib -. "readDir hosts/\nfilter .nix / default.nix" .-> hosts["hosts/*.nix\nhosts/*/default.nix\n{system,isNixOS,users,features,\n nixosModules,homeModules}"]
    featLib -. "readDir features/\nknown={nixos,home,overlays}" .-> features["features/*/home.nix\nfeatures/*/nixos.nix\nfeatures/*/_overlays.nix (optional)\n+ _package.nix/bin/*.sh (feature-internal)"]

    builders -- "consumed at build time" --> nixSettings["modules/nix-settings.nix\nsubstituters + nix.package"]
    builders -- "consumed at build time" --> defaults["modules/defaults/home-manager.nix\nmodules/defaults/nixos.nix (merged)"]
    libDefault -- "exposes" --> flakeOut["flake.nixosConfigurations\nflake.homeConfigurations"]
    flake -. "devShells.x86_64-linux.default" .-> devShell["pkgs.mkShell git pkgconf cmake"]

    style libDefault fill:#e8f5e9
    style featLib fill:#e8f5e9
    style hostsLib fill:#e8f5e9
    style builders fill:#e8f5e9
    style hostOpts fill:#e8f5e9
    style hosts fill:#fff9c4
    style features fill:#fff3e0
```

`lib/` files have no `options`/`config` at top level — pure functions. `lib/default.nix` is the sole impure wiring layer (`readDir`, `import`, `evalModules` for host validation only). `nix-settings.nix` and `defaults/*` are not statically imported by `lib/default.nix`; they are injected by the `buildNixosConfigurations`/`buildHomeConfigurations` builders in `lib/builders.nix`.

---

## Build Pipeline

Evaluation order in `lib/default.nix` → concern files.

```mermaid
flowchart LR
    subgraph Disc ["Discovery — lib/hosts.nix"]
        scan["readDir hosts/\nfilter regular .nix\nor dir/default.nix"] --> parse["parseHostEntry\n{isDir,name,path,hostDir}"]
        parse --> validate["validateHost\nevalModules [hostOptions,\n import path,\n implied-user module]"]
        validate --> auto["autoDiscoverModules\nif isDir: nixos.nix?\n+ home-*.nix → homeModules"]
        auto --> enrich["enrichHost\ncfg.users = implied + authored (typed defaults)\nenabled → osUsernames\n+ has home module → hmUsernames"]
        enrich --> discovered["discoveredHosts\nmapAttrs buildHost"]
    end
    subgraph Pkgs ["Overlay & pkgs — lib/default.nix"]
        overlays["resolveHostOverlays (lib/features.nix)\n reads _overlays.nix per feature\n (no module import, no pkgs=null)\n → unique concat list"]
        mkPkgs["hostsWithPkgs\nmapAttrs host:\n pkgs = nixpkgs + baseOverlay + host overlays\n baseOverlay: pinMeta, flakePackages, unstable\n (unstable set = nixpkgs-unstable + baseOverlay)\n allowUnfree=true\n → builders: nixpkgs.pkgs = host.pkgs"]
        overlays --> mkPkgs
    end
    subgraph Out ["Builders — lib/builders.nix"]
        nixos["buildNixosConfigurations\nfilter isNixOS\n→ nixosSystem per host"]
        hm["buildHomeConfigurations\nfilter !isNixOS\n→ homeManagerConfiguration\n per user@host"]
    end
    discovered --> overlays
    mkPkgs --> nixos & hm

    checkWarn["admin warning (modules/host-facts.nix)\nisNixOS=false + isAdmin → warning"] -.-> discovered
```

`hostsWithPkgs` computed once in `lib/default.nix` and shared by both builders — single overlay resolution per host.

---

## Host Type Resolution

```mermaid
flowchart TD
    f["hosts/<name>.nix\nor hosts/<name>/default.nix"] --> v["validateHost (lib/hosts.nix)\n hostOptions.isNixOS default false"]
    v --> q{"cfg.isNixOS?"}
    q -->|true| N["NixOS host\nbuildNixosConfigurations filter isNixOS\n→ nixosConfigurations.<name>\n+ homeConfigurations.<user>@<name>\n(via home-manager.users)"]
    q -->|false| H["HM-only host\nbuildHomeConfigurations filter !isNixOS\n→ homeConfigurations.<user>@<name>\n(homeManagerConfiguration)"]

    N -.-> warnCheck{"admin warning (modules/host-facts.nix)\nisNixOS=false && isAdmin?"}
    H -.-> warnCheck
    warnCheck -->|admin on HM| warn["warning: isAdmin is no-op\non standalone HM"]

    style N fill:#c8e6c9
    style H fill:#fff9c4
```

`isQemuVM` and `bootstrap` (declared in `hostOptions`, `lib/host-options.nix`) are orthogonal — they don't affect host classification, only feature/overlay gating downstream.

---

## Feature System

```mermaid
flowchart LR
    subgraph Discover ["Discovery — lib/features.nix"]
        scan["readDir features/\nfilter directories"] --> map["discoveredFeatures\nmapAttrs featureDir\n knownFiles={nixos,home,overlays}\n→ {feature: {nixos?:path, home?:path, overlays?:path}}"]
    end
    subgraph Resolve ["Resolution — lib/features.nix"]
        resolve["resolveFeaturePaths\nfor f in featureList:\n read discoveredFeatures.f (no re-walk)\n hasAttr platform → [path]\n else [] (hybrid skip)\n else throw 'Unknown … Available: …'"]
        collect["resolveHostOverlays\n for each feature:\n feature.overlays present?\n → import {inputs} → list\n → unique concatLists"]
        resolve --> collect
    end
    subgraph Consume ["Consumption"]
        nixosUse["nixosSystem (lib/builders.nix)\nimports = resolve nixos + modules/feature-options.nix"]
        hmUse["mkUserHomeModule (lib/builders.nix)\nimports = resolve home + modules/feature-options.nix\n+ defaults/home-manager.nix"]
        pkgsUse["hostsWithPkgs (lib/default.nix)\npkgs members: pinMeta, flakePackages, unstable"]
    end
    map --> resolve
    collect --> pkgsUse
    resolve --> nixosUse & hmUse

    featOpt["modules/feature-options.nix\nfeature enable/disable options\nextraGroups (by-key attrset; warns if\n non-empty and users.users missing)"] -. contributes .-> nixosUse
```

A single walker owns discovery: `discoveredFeatures` is the one `readDir`, and `resolveFeaturePaths` resolves each listed feature against it (no second `pathExists` walk). Unknown feature throws with a sorted `Available:` list; a listed feature with no module for the requested platform resolves to `[]` (hybrid skip). Extras like `_package.nix`/`bin/*.pyz` are not discovered — the feature's own `home.nix`/`nixos.nix` imports them. `_overlays.nix` is part of the same discovery map (`knownFiles`), so `resolveHostOverlays` imports the discovered path — no second walk.

**Listing a feature means it is enabled.** Every top-level `features.<name>.enable` defaults to `true` (`mkEnableOption … // {default = true;}`), so a host only lists the features it wants on; `enable = false` is the opt-out, and any per-feature attrs are knobs (e.g. `oomd.notify`, `dms.niriCompat`, `niri.niri-watcher.enable`). Sub-knobs that are opt-in (e.g. `niri.kanshi.enable`) stay default-false.

---

## Configuration Composition

### NixOS Host — `buildNixosConfigurations` (`lib/builders.nix`)

```mermaid
flowchart LR
    subgraph Mods ["nixosSystem modules — flattened"]
        feat["1 feature aggregator\n imports = resolveFeaturePaths 'nixos'\n + modules/feature-options.nix"]
        nixSet["2 nix-settings\nsubstituters + nix.package"]
        defNixos["3 defaults/nixos.nix\nstateVersion + fish + kernel\n+ genAttrs osUsernames → users.users\n  (+ extraGroups for isAdmin)"]
        hostMods["4 host.nixosModules\n auto nixos.nix + cfg.nixosModules"]
        hmMod["5 home-manager.nixosModules.home-manager"]
        inline["6 inline\n nixpkgs.pkgs = host.pkgs\n home-manager {useGlobalPkgs,\n  extraSpecialArgs, users=genAttrs hmUsernames\n   mkUserHomeModule}"]
        facts["7 mkHostFactsModule\n config.flakeHost"]
        feat --> nixSet --> defNixos --> hostMods --> hmMod --> inline --> facts --> merged["nixosSystem"]
    end
    subgraph Args ["specialArgs"]
        sa["inputs only"]
    end
    sa -.-> merged
```

`mkUserHomeModule` chain per user (`lib/builders.nix`): `resolve home` + `host.homeModules.<user>` + `modules/feature-options.nix` + `defaults/home-manager.nix` + `mkHostFactsModule host`. The builder sets `home.username` and `home.homeDirectory` (`mkDefault`). Nothing else is threaded: `pkgs` is a module value (`nixpkgs.pkgs`), and the host's unstable set is a member of it (`pkgs.unstable`).

### HM-Only Host — `buildHomeConfigurations` (`lib/builders.nix`)

```mermaid
flowchart LR
    subgraph Pkgs ["pkgs — lib/default.nix pre-built"]
        pkgsNode["pkgs = nixpkgs + baseOverlay + host overlays\nmembers: pinMeta, flakePackages, unstable"]
    end
    subgraph Mods2 ["homeManagerConfiguration modules"]
        nixSet2["nix-settings.nix"]
        userMod["mkUserHomeModule\n resolve 'home' + host.homeModules.<user>\n + modules/feature-options.nix\n + defaults/home-manager.nix"]
        generic["targets.genericLinux.enable\n = lib.mkDefault true"]
        nixSet2 --> userMod --> generic --> merged2["homeManagerConfiguration"]
    end
    pkgsNode --> merged2
```

---

## Data Flow Summary

```mermaid
graph LR
    hosts["hosts/"] -- readDir --> disc["lib/hosts.nix\ndiscoveredHosts"]
    features["features/"] -- readDir --> featMap["lib/features.nix\ndiscoveredFeatures"]
    featMap -- "_overlays.nix" --> hostsWithPkgs["hostsWithPkgs\nlib/default.nix\nresolveHostOverlays\n→ pkgs (pinMeta, flakePackages, unstable)"]
    disc --> hostsWithPkgs
    hostsWithPkgs --> nixosOut["nixosConfigurations\nlib/builders.nix"]
    hostsWithPkgs --> hmOut["homeConfigurations\nlib/builders.nix"]

    style disc fill:#e1f5fe
    style featMap fill:#e8f5e9
    style hostsWithPkgs fill:#c8e6c9
```

---

## Key Design Decisions

| Decision                                     | Rationale                                                                                                                                                                                                                                                                                    |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/` directory (was single `lib.nix`)      | Split by concern: `host-options`, `features`, `hosts`, `builders`; `default.nix` is the composition root re-exporting the public surface                                                                                                                                                     |
| `hardware-configuration.nix` stays generated | The barrel imports it first and `base.nix` authors loader/ssh/services on top, so `nixos-generate-config` can overwrite the disk description with no config edits (methyl, methyl-nixos, propyl)                                                                                          |
| `isNixOS` bool                               | Explicit host classification; `false` default keeps HM-only hosts terse                                                                                                                                                                                                                      |
| `system` in host file                        | Single source of truth for `pkgs` system                                                                                                                                                                                                                                                     |
| Flat `hosts/<name>.nix` + directory hosts    | Simple hosts stay one file; complex hosts auto-discover `nixos.nix`/`home-*.nix`                                                                                                                                                                                                             |
| Feature dirs auto-discovered                 | No registry; add `features/foo/{home,nixos}.nix` and list `"foo"` in host — **listing = enabled** (`enable` defaults to `true`; `false` is the opt-out, per-feature attrs are knobs)                                                                                                         |
| `_overlays.nix` per feature                  | Features that need overlays ship `{inputs, ...}: [ … ]` in `_overlays.nix`; `resolveHostOverlays` imports it directly — no module eval, no `pkgs = null` sentinel
| `pinMeta` as one package-set member          | `metadata.json` pins share one shape contract, so `lib/pin-meta.nix` owns the URL template, system lookup, and arches/hash shape check; the whole attrset is one member of `baseOverlay`, present in every package set, so `callPackage` hands it to `_package.nix` as a build dependency (`pinMeta.releaseAsset pin system`) (feature `_overlays.nix` reaches `pkgs` only)                              |
| `baseOverlay` members: `pinMeta`, `flakePackages`, `unstable` | Flake inputs that publish `packages` land in the host set, so a flake package read in a feature module is a module value (`flakePackages.<name>.<system>.default`); `self` is excluded because a future `packages` output would point back at the host configs and cycle; the unstable set carries `baseOverlay` only, so `pkgs.unstable` never asks for itself |
| Hosts keyed by their own name (`lib/hosts.nix`) | `hosts/<name>.nix` and `hosts/<name>/default.nix` yield one key — `<user>@<host>` in `homeConfigurations` and `nixosConfigurations.<host>` — so every public output names a host the same way; two definitions resolving to one name throw at discovery |
| `flakeHost` as one option (`modules/host-facts.nix`) | Host facts reach modules through a single declared `config.flakeHost`, typed from the schema groups in `lib/host-options.nix` (`hostFacts`, `authoringOptions`, `derivedOptions` — no key list subtracted at runtime), so any host attribute the schema declares is a fact and an undeclared one is a type error instead of a silent default; `osUsernames`/`hmUsernames` derive from the typed `users` set, never written by a host |
| `networking.hostName = mkDefault config.flakeHost.name` (`modules/defaults/nixos.nix`) | Discovery owns the name: `lib/hosts.nix` takes it from the `hosts/` directory or file name and re-injects it after the host config merges, so a host file cannot override it and a new host costs no `hostName` line |
| `specialArgs = {inherit inputs;}` | Only the flake inputs stay injected: three features build module paths from them at import time (`inputs.agenix.homeManagerModules.default` is evaluated before the module system runs). Package sets and host facts are module values instead (`nixpkgs.pkgs`, its `unstable` member, `config.flakeHost`) |
| `hostsWithPkgs` in `lib/default.nix`         | Overlays resolved once, `pkgs` shared by both builders and reachable as `nixosConfigurations.<host>.pkgs` / `homeConfigurations.<user>@<host>.pkgs`; the loader keeps it internal because `nix flake check` warns on non-standard outputs and a public copy would drift from the configs                          |
| `modules/defaults/*` collapsed (2 files)     | `home-manager.nix` (stateVersion, manual off, the nixGL `wrapMesa` wrapper) + merged `nixos.nix` (stateVersion/shell/kernel + `users.users` + `extraGroups` for `isAdmin`); always-on, so consumers call `config.lib.nixGL.wrapMesa` without a fallback |
| `bootstrap` flag                             | Gates cache-dependent options during first deploy (`bootstrap.sh`)                                                                                                                                                                                                                           |
| `hmEnabled` per user                         | NixOS user exists without HM when `false`                                                                                                                                                                                                                                                    |
| `extraGroups` aggregation                    | Features declare groups as a **by-key attrset** (`extraGroups = { foo = ["grp"]; }`); the single consumer (`defaults/nixos.nix`) flattens `attrValues` for `isAdmin` users — no last-wins collision, no `lib.mkAppend` (absent in nixpkgs). Warns if non-empty and `users.users` unavailable |
| Plain `flake.nix` outputs (no `flake-parts`) | Single `x86_64-linux` system, `devShells.x86_64-linux.default` inline; removed framework tax (1 input, ~30 lock lines)                                                                                                                                                                       |
| Public outputs are the configs only          | `nixosConfigurations` + `homeConfigurations` (+ `devShells`) are the only exports: `features` was a public copy of a value the loader already has, and a package-set output would duplicate `<config>.pkgs`, so `nix flake check` reports no unchecked outputs and inspection reads one path                                                          |
