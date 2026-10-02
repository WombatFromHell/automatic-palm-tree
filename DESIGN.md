# DESIGN — Architecture & Dependencies

## File Layout

```
flakeroot/
├── flake.nix                       # plain outputs (no flake-parts), calls ./modules
├── lib/                            # pure lib, split by concern
│   ├── default.nix                 #   composition root — re-exports all concern files
│   ├── host-options.nix            #   hostOptions schema
│   ├── features.nix                #   feature discovery + _overlays.nix resolution
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
│   └── methyl-nixos/               # NixOS host (QEMU VM — reuses methyl/)
│       ├── default.nix
│       ├── nixos.nix
│       ├── home-josh.nix           #   re-imports ../methyl/home-josh.nix
│       └── hardware-configuration.nix
├── features/                       # 38 composable units, auto-discovered
│   ├── hm-only    (13)             #   home.nix only
│   ├── nixos-only (17)             #   nixos.nix only
│   ├── hybrid      (8)             #   home.nix + nixos.nix: hm-syncthing, nixos-dmemcg, nixos-dms, nixos-flatpak, nixos-kde, nixos-lsfg, nixos-niri, nixos-oom
│   ├── _overlays.nix               #   optional: {inputs, ...}: [ … ] per feature
│   └── extras                      #   _package.nix / _*.nix / bin/ / *.sh imported by the feature itself
├── modules/
│   ├── default.nix                 # thin composition: overlays → pkgs → flake outputs
│   ├── bootstrap.nix               # swapfile+zswap for /etc/nixos/swap-prepare.nix (bootstrap.sh)
│   ├── nix-settings.nix            # substituters, trusted keys, nix.package
│   ├── defaults/
│   │   ├── home-manager.nix        # stateVersion, manual off, username/homeDirectory
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
    flake["flake.nix\nplain outputs, no flake-parts\nimports ./modules as function"] --> modDefault["modules/default.nix\nthin composition:\noverlays → pkgs → flake outputs"]

    modDefault -- "import ../lib" --> libDefault["lib/default.nix\ncomposition root\nre-exports all concern files"]

    libDefault --> hostOpts["lib/host-options.nix\nhostOptions schema"]
    libDefault --> featLib["lib/features.nix\ndiscoveredFeatures\nresolveFeaturePaths\nresolveHostOverlays\nfeatureOptionsModule"]
    libDefault --> hostsLib["lib/hosts.nix\nparseHostEntry, validateHost\nautoDiscoverModules\nenrichHost, buildHost\ndiscoveredHosts"]
    libDefault --> builders["lib/builders.nix\nbuildNixosConfigurations\nbuildHomeConfigurations\ncheckAdminWarning"]

    hostsLib -. "readDir hosts/\nfilter .nix / default.nix" .-> hosts["hosts/*.nix\nhosts/*/default.nix\n{system,isNixOS,users,features,\n nixosModules,homeModules}"]
    featLib -. "readDir features/\nknown={nixos,home}" .-> features["features/*/home.nix\nfeatures/*/nixos.nix\nfeatures/*/_overlays.nix (optional)\n+ _package.nix/bin/*.sh (feature-internal)"]

    builders -- "consumed at build time" --> nixSettings["modules/nix-settings.nix\nsubstituters + nix.package"]
    builders -- "consumed at build time" --> defaults["modules/defaults/home-manager.nix\nmodules/defaults/nixos.nix (merged)"]
    modDefault -- "re-exposes" --> flakeOut["flake.features\nflake.nixosConfigurations\nflake.homeConfigurations\nflake.hostPackageSets"]
    flake -. "devShells.x86_64-linux.default" .-> devShell["pkgs.mkShell git pkgconf cmake"]

    style libDefault fill:#e8f5e9
    style featLib fill:#e8f5e9
    style hostsLib fill:#e8f5e9
    style builders fill:#e8f5e9
    style hostOpts fill:#e8f5e9
    style modDefault fill:#e1f5fe
    style hosts fill:#fff9c4
    style features fill:#fff3e0
```

`lib/` files have no `options`/`config` at top level — pure functions. `modules/default.nix` is the sole impure wiring layer (`readDir`, `import`, `evalModules` for host validation only). `nix-settings.nix` and `defaults/*` are not statically imported by `modules/default.nix`; they are injected by the `buildNixosConfigurations`/`buildHomeConfigurations` builders in `lib/builders.nix`.

---

## Build Pipeline

Evaluation order in `modules/default.nix` → `lib/`.

```mermaid
flowchart LR
    subgraph Disc ["Discovery — lib/hosts.nix"]
        scan["readDir hosts/\nfilter regular .nix\nor dir/default.nix"] --> parse["parseHostEntry\n{isDir,name,path,hostDir}"]
        parse --> validate["validateHost\nevalModules [hostOptions,\n import path]"]
        validate --> auto["autoDiscoverModules\nif isDir: nixos.nix?\n+ home-*.nix → homeModules"]
        auto --> enrich["enrichHost\nimpliedUsers from homeModules\nmergedUsers = implied // cfg.users\nenabled → osUsernames\nfiltered → hmUsernames"]
        enrich --> discovered["discoveredHosts\nmapAttrs buildHost"]
    end
    subgraph Pkgs ["Overlay & pkgs — modules/default.nix"]
        overlays["resolveHostOverlays (lib/features.nix)\n reads _overlays.nix per feature\n (no module import, no pkgs=null)\n → unique concat list"]
        mkPkgs["hostsWithPkgs\nmapAttrs host:\n pkgs= nixpkgs+overlays\n pkgsUnstable= nixpkgs-unstable\n allowUnfree=true"]
        overlays --> mkPkgs
    end
    subgraph Out ["Builders — lib/builders.nix"]
        nixos["buildNixosConfigurations\nfilter isNixOS\n→ nixosSystem per host"]
        hm["buildHomeConfigurations\nfilter !isNixOS\n→ homeManagerConfiguration\n per user@host"]
    end
    discovered --> overlays
    mkPkgs --> nixos & hm

    checkWarn["checkAdminWarning (lib/builders.nix)\nisNixOS=false + isAdmin → warning"] -.-> discovered
```

`hostsWithPkgs` computed once in `modules/default.nix` and shared by both builders — single overlay resolution per host.

---

## Host Type Resolution

```mermaid
flowchart TD
    f["hosts/<name>.nix\nor hosts/<name>/default.nix"] --> v["validateHost (lib/hosts.nix)\n hostOptions.isNixOS default false"]
    v --> q{"cfg.isNixOS?"}
    q -->|true| N["NixOS host\nbuildNixosConfigurations filter isNixOS\n→ nixosConfigurations.<name>\n+ homeConfigurations.<user>@<name>\n(via home-manager.users)"]
    q -->|false| H["HM-only host\nbuildHomeConfigurations filter !isNixOS\n→ homeConfigurations.<user>@<name>\n(homeManagerConfiguration)"]

    N -.-> warnCheck{"checkAdminWarning (lib/builders.nix)\nisNixOS=false && isAdmin?"}
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
        scan["readDir features/\nfilter directories"] --> map["discoveredFeatures\nmapAttrs featureDir\n known=[nixos,home]\n→ {feature: {nixos?:path, home?:path}}\n(exposed as flake.features)"]
    end
    subgraph Resolve ["Resolution — lib/features.nix"]
        resolve["resolveFeaturePaths\nfor f in featureList:\n read discoveredFeatures.f (no re-walk)\n hasAttr platform → [path]\n else [] (hybrid skip)\n else throw 'Unknown … Available: …'"]
        collect["resolveHostOverlays\n for each feature:\n pathExists _overlays.nix?\n → import {inputs} → list\n → unique concatLists"]
        resolve --> collect
    end
    subgraph Consume ["Consumption"]
        nixosUse["nixosSystem (lib/builders.nix)\nimports = resolve nixos + featureOptionsModule"]
        hmUse["mkUserHomeModule (lib/builders.nix)\nimports = resolve home + featureOptionsModule\n+ defaults/home-manager.nix"]
        pkgsUse["hostsWithPkgs (modules/default.nix)\npkgs←overlays, pkgsUnstable←plain"]
    end
    map --> resolve
    collect --> pkgsUse
    resolve --> nixosUse & hmUse

    featOpt["featureOptionsModule (lib/features.nix)\nextraGroups (by-key attrset; warns if\n non-empty and users.users missing)"] -. contributes .-> nixosUse
```

A single walker owns discovery: `discoveredFeatures` is the one `readDir`, and `resolveFeaturePaths` resolves each listed feature against it (no second `pathExists` walk). Unknown feature throws with a sorted `Available:` list; a listed feature with no module for the requested platform resolves to `[]` (hybrid skip). Extras like `_package.nix`/`bin/*.pyz` are not discovered — the feature's own `home.nix`/`nixos.nix` imports them. Overlays are declared in a separate `_overlays.nix` file per feature (`{inputs, ...}: [ … ]`) — imported directly by `resolveHostOverlays`, no module eval needed.

**Listing a feature means it is enabled.** Every top-level `features.<name>.enable` defaults to `true` (`mkEnableOption … // {default = true;}`), so a host only lists the features it wants on; `enable = false` is the opt-out, and any per-feature attrs are knobs (e.g. `oomd.notify`, `dms.niriCompat`, `niri.niri-watcher.enable`). Sub-knobs that are opt-in (e.g. `niri.kanshi.enable`) stay default-false.

---

## Configuration Composition

### NixOS Host — `buildNixosConfigurations` (`lib/builders.nix`)

```mermaid
flowchart LR
    subgraph Mods ["nixosSystem modules — flattened"]
        feat["1 feature aggregator\n imports = resolveFeaturePaths 'nixos'\n + featureOptionsModule"]
        nixSet["2 nix-settings\nsubstituters + nix.package"]
        defNixos["3 defaults/nixos.nix\nstateVersion + fish + kernel\n+ genAttrs osUsernames → users.users\n  (+ extraGroups for isAdmin)"]
        hostMods["4 host.nixosModules\n auto nixos.nix + cfg.nixosModules"]
        hmMod["5 home-manager.nixosModules.home-manager"]
        inline["6 inline\n allowUnfree,\n _module.args.pkgsUnstable,\n home-manager {useGlobalPkgs,\n  extraSpecialArgs, users=genAttrs hmUsernames\n   mkUserHomeModule}"]
        feat --> nixSet --> defNixos --> hostMods --> hmMod --> inline --> merged["nixosSystem"]
    end
    subgraph Args ["specialArgs"]
        sa["inputs, self, hostConfig"]
    end
    sa -.-> merged
```

`mkUserHomeModule` chain per user (`lib/builders.nix`): `resolve home` + `host.homeModules.<user>` + `featureOptionsModule` + `defaults/home-manager.nix` + `_module.args.user`.

### HM-Only Host — `buildHomeConfigurations` (`lib/builders.nix`)

```mermaid
flowchart LR
    subgraph Pkgs ["pkgs — modules/default.nix pre-built"]
        stable["pkgs = nixpkgs + stable overlays"]
        unstable["pkgsUnstable = nixpkgs-unstable + unstable\nalso in extraSpecialArgs"]
    end
    subgraph Mods2 ["homeManagerConfiguration modules"]
        nixSet2["nix-settings.nix"]
        userMod["mkUserHomeModule\n resolve 'home' + host.homeModules.<user>\n + featureOptionsModule\n + defaults/home-manager.nix"]
        generic["targets.genericLinux.enable\n = lib.mkDefault true"]
        nixSet2 --> userMod --> generic --> merged2["homeManagerConfiguration"]
    end
    stable --> merged2
    unstable -. extraSpecialArgs .-> merged2
```

---

## Data Flow Summary

```mermaid
graph LR
    hosts["hosts/"] -- readDir --> disc["lib/hosts.nix\ndiscoveredHosts"]
    features["features/"] -- readDir --> featMap["lib/features.nix\ndiscoveredFeatures"]
    featMap -- "_overlays.nix" --> hostsWithPkgs["hostsWithPkgs\nmodules/default.nix\nresolveHostOverlays\n→ pkgs / pkgsUnstable"]
    disc --> hostsWithPkgs
    hostsWithPkgs --> nixosOut["nixosConfigurations\nlib/builders.nix"]
    hostsWithPkgs --> hmOut["homeConfigurations\nlib/builders.nix"]
    hostsWithPkgs --> pkgSets["hostPackageSets\nmodules/default.nix"]
    featMap --> flakeFeat["flake.features"]

    style disc fill:#e1f5fe
    style featMap fill:#e8f5e9
    style hostsWithPkgs fill:#c8e6c9
```

---

## Key Design Decisions

| Decision                                     | Rationale                                                                                                                                                                                                                                                                                    |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/` directory (was single `lib.nix`)      | Split by concern: `host-options`, `features`, `hosts`, `builders`; `default.nix` is the composition root re-exporting the public surface                                                                                                                                                     |
| `isNixOS` bool                               | Explicit host classification; `false` default keeps HM-only hosts terse                                                                                                                                                                                                                      |
| `system` in host file                        | Single source of truth for `pkgs` system                                                                                                                                                                                                                                                     |
| Flat `hosts/<name>.nix` + directory hosts    | Simple hosts stay one file; complex hosts auto-discover `nixos.nix`/`home-*.nix`                                                                                                                                                                                                             |
| Feature dirs auto-discovered                 | No registry; add `features/foo/{home,nixos}.nix` and list `"foo"` in host — **listing = enabled** (`enable` defaults to `true`; `false` is the opt-out, per-feature attrs are knobs)                                                                                                         |
| `_overlays.nix` per feature                  | Features that need overlays ship `{inputs, ...}: [ … ]` in `_overlays.nix`; `resolveHostOverlays` imports it directly — no module eval, no `pkgs = null` sentinel                                                                                                                            |
| `hostsWithPkgs` in `modules/default.nix`     | Overlays resolved once, `pkgs`/`pkgsUnstable` reused by builders and exposed as `hostPackageSets`                                                                                                                                                                                            |
| `modules/defaults/*` collapsed (2 files)     | `home-manager.nix` + merged `nixos.nix` (stateVersion/shell/kernel + `users.users` + `extraGroups` for `isAdmin`); not duplicated per host                                                                                                                                                   |
| `bootstrap` flag                             | Gates cache-dependent options during first deploy (`bootstrap.sh`)                                                                                                                                                                                                                           |
| `hmEnabled` per user                         | NixOS user exists without HM when `false`                                                                                                                                                                                                                                                    |
| `extraGroups` aggregation                    | Features declare groups as a **by-key attrset** (`extraGroups = { foo = ["grp"]; }`); the single consumer (`defaults/nixos.nix`) flattens `attrValues` for `isAdmin` users — no last-wins collision, no `lib.mkAppend` (absent in nixpkgs). Warns if non-empty and `users.users` unavailable |
| Plain `flake.nix` outputs (no `flake-parts`) | Single `x86_64-linux` system, `devShells.x86_64-linux.default` inline; removed framework tax (1 input, ~30 lock lines)                                                                                                                                                                       |
