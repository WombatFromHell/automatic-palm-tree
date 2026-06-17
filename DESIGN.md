# DESIGN — Architecture & Dependencies

## File Layout

```
flakeroot/
├── flake.nix                        # flake-parts entry, imports ./modules
├── hosts/                           # per-host declarations
│   ├── methyl-bazzite.nix           # HM-only host
│   └── methyl-nixos/                # NixOS host (dir = auto-discovered modules)
│       ├── default.nix              #   schema: system, features, users
│       ├── nixos.nix                #   host-local NixOS module
│       ├── home-josh.nix            #   per-user Home Manager module
│       └── hardware-configuration.nix
├── features/                        # composable config units (30 dirs)
│   ├── hm-base/
│   ├── hm-dev/
│   ├── nixos-base/
│   └── ...
├── lib/                             # pure Nix library (no options/config)
│   ├── builders.nix                 # mkHostContext + NixOS/HM build fns (pkgs, overlays, unfree)
│   ├── features.nix                 # discoveredFeatures: scan features/ → map
│   ├── host-schema.nix              # host declaration validation schema
│   ├── builder-helpers.nix          # mkPkgs, mkUserHomeModule, resolveHostModules
│   └── host-discovery.nix           # autoDiscoverModules, enrichHost (pure fns)
└── modules/                         # flake-parts + NixOS/HM modules
    ├── default.nix                  # flake-parts: wires builders + flakeModules + flake.features
    ├── discovery.nix                # discoveredHosts option: readDir hosts/ → pipeline
    ├── nix-settings.nix             # nix daemon config (substituters, keys)
    ├── nixos.nix                    # NixOS flake module (stateVersion, fish, user shells)
    └── home-manager.nix             # HM flake module (stateVersion, manual, nh)
```

---

## Module Dependency Graph

Static import relationships between all module files.

```mermaid
graph TB
    subgraph Entry ["Flake Entry"]
        flake["flake.nix\nflake-parts + imports ./modules"]
    end

    subgraph Mods ["modules/"]
        modsDefault["modules/default.nix\nimports builders + exposes\nflakeModules + flake.features"]
        disc["modules/discovery.nix\nreadDir hosts/ → discoveredHosts"]
        nixSettings["modules/nix-settings.nix\nsubstituters + trusted keys + nix.package"]
    end

    subgraph Lib ["lib/ (pure functions)"]
        feat["lib/features.nix\nscan features/ → discoveredFeatures"]
        schema["lib/host-schema.nix\nvalidation schema for host files"]
        bld["lib/builders.nix\nmkHostContext + resolveFeaturePaths\n+ NixOS/HM build fns"]
    end

    subgraph HMMod ["HM flake module"]
        hmMod["modules/home-manager.nix\nstateVersion + nh + manual"]
    end

    subgraph NixOSMod ["NixOS flake module"]
        nixOSMod["modules/nixos.nix\nstateVersion + fish + user shells"]
    end

    subgraph Features ["Feature Modules (discovered)"]
        hmBase["features/hm-base/home.nix"]
        hmDev["features/hm-dev/home.nix"]
        hmGpg["features/hm-gpg/home.nix"]
        moreFeat["... (30 feature dirs)"]
    end

    subgraph Hosts ["Host Configs (discovered)"]
        hostFiles["hosts/*.nix / hosts/*/default.nix\n{system, isNixOS, features, users,\n nixosModules, sharedModules, homeModules}"]
    end

    flake --> modsDefault

    modsDefault --> bld
    modsDefault --> feat

    bld --> disc
    bld --> nixSettings

    disc --> schema

    hmMod --> nixSettings
    nixOSMod --> nixSettings

    style Mods fill:#e1f5fe
    style Lib fill:#e8f5e9
    style Builders fill:#c8e6c9
    style HMMod fill:#f3e5f5
    style NixOSMod fill:#f3e5f5
    style Features fill:#fff3e0
    style Hosts fill:#fff9c4
```

---

## Build Pipeline

Runtime evaluation flow from flake entry to final configurations.

```mermaid
flowchart LR
    subgraph E ["Entry: flake.nix"]
        fp["flake-parts.lib.mkFlake\nimports ./modules"]
    end

    subgraph M ["modules/default.nix"]
        mm["imports builders\n+ exposes flake.flakeModules\n+ flake.features"]
    end

    subgraph D ["Discovery (modules/discovery.nix)"]
        scan["readDir hosts/"]
        importHost["import each host/*.nix"]
        validate["evalModules against lib/host-schema.nix"]
        enrich["derive osUsernames + hmUsernames\n+ merge auto-discovered modules"]
    end

    subgraph B ["Builders (lib/builders.nix)"]
        resolveFeat["resolveFeaturePaths\nsingle pass: feature modules\n+ overlay paths per platform"]
        collectU["collectUnfreeFromModules\nbatch: all feature modules\n(nixos + home combined)"]
        mkPkgsSet["mkPkgs → pkgsStable + pkgsUnstable\n(allowUnfreePredicate)\nonly homeOverlays applied"]
        filterN["filter: isNixOS == true"]
        nixosSys["nixpkgs.lib.nixosSystem\nmodules: nix-settings + flakeModules.nixos\n+ nixos features + host modules\n+ home-manager (per-user)"]
        filterH["filter: isNixOS == false"]
        hmConfig["homeManagerConfiguration\npkgs = host.pkgsStable (with homeOverlays)\nmodules: nix-settings + per-user\n+ home features + host modules"]
    end

    fp --> M

    M --> D
    M --> B

    scan --> importHost --> validate --> enrich

    enrich --> resolveFeat
    enrich --> collectU
    enrich --> mkPkgsSet

    mkPkgsSet --> nixosSys
    mkPkgsSet --> hmConfig

    style M fill:#e1f5fe
    style D fill:#e1f5fe
    style B fill:#c8e6c9
```

---

## Host Type Resolution

A host file is classified by its `isNixOS` field in the schema.

```mermaid
flowchart TD
    Start(["hosts/<name>.nix"]) --> read["import file"]
    read --> schema["validate against\nlib/host-schema.nix"]
    schema --> isNixOS{"isNixOS == true?"}

    isNixOS -->|yes| nixosHost["NixOS host"]
    isNixOS -->|no| hmOnly["Home Manager–only host"]

    nixosHost --> nixosOut["nixosConfigurations.<name>\n+ homeConfigurations.<user>@<name>"]
    hmOnly --> hmOut["homeConfigurations.<user>@<name>"]

    style nixosHost fill:#c8e6c9,stroke:#333
    style hmOnly fill:#fff9c4,stroke:#333
```

---

## Feature System

Features are auto-discovered from `features/<name>/` directories. Each directory contains platform-tagged `.nix` files (e.g., `home.nix`, `nixos.nix`). Resolution is handled by `lib/builders.nix`, which silently skips features without a module for the requested platform and throws on unknown feature names.

```mermaid
flowchart LR
    subgraph Discover ["Discovery (lib/features.nix)"]
        scan["readDir features/"]
        map["map → {<feature>: {<platform>: path}}"]
    end

    subgraph HostCtx ["Resolution (lib/builders.nix)"]
        validate["resolveFeaturePaths\nsingle pass: modules + overlay paths\nunknown → throw, missing → skip"]
        unfree["collectUnfreeFromModules\nbatch across all feature modules\n(nixos + home combined)"]
        ctxOut["host context carries\nnixosModules + homeModules\n+ pkgsStable + pkgsUnstable\n+ homeOverlays"]
    end

    subgraph Builders ["Builder Usage"]
        nixosFeat["nixos.nix:\nhost.nixosModules in nixosSystem"]
        hmFeat["home-manager.nix:\nhost.homeModules in\nmkUserHomeModule chain"]
    end

    scan --> map

    map --> validate --> unfree --> ctxOut

    ctxOut --> nixosFeat
    ctxOut --> hmFeat

    style Discover fill:#e3f2fd
    style HostCtx fill:#e8f5e9
    style Builders fill:#f5f5f5
```

---

## Configuration Composition

### NixOS Host

```mermaid
flowchart LR
    subgraph M["Modules (merged via lib.flatten)"]
        nixSet["modules/nix-settings.nix\n(substituters, trusted keys, nix.package)"]
        nixosMod["modules/nixos.nix\n(stateVersion, fish, user shells)"]
        autoUser["mkNixosUserModule\n(genAttrs osUsernames → users.users)"]
        featMod["host.nixosModules\n(resolved NixOS features)"]
        hostMod["resolveHostModules host 'nixos'\n(host-local + shared modules)"]
        hmMod["home-manager.nixosModules.home-manager"]
        hmCfg["hmUsernames →\n mkUserHomeModule\n(per-user feature + host + unfree chain)"]
        extra["unfreeOptionsModule\ndeterminate (if !bootstrap)\ndms.nixosModules"]
    end
    subgraph SA["specialArgs"]
        inputs["inputs + self"]
        osUsernames["host.osUsernames"]
        hmUsernames["host.hmUsernames"]
    end
    nixSet --> merged["inputs.nixpkgs.lib.nixosSystem"]
    nixosMod --> merged
    autoUser --> merged
    featMod --> merged
    hostMod --> merged
    hmMod --> merged
    hmCfg --> merged
    extra --> merged
    style M fill:#e3f2fd
```

### Home Manager–Only Host

```mermaid
flowchart LR
    subgraph M["Modules"]
        nixSet["modules/nix-settings.nix"]
        baseModule["mkUserHomeModule\n(home features + host modules\n+ per-user mods + unfree)"]
        generic["targets.genericLinux.enable"]
    end
    subgraph EA["extraSpecialArgs"]
        pkgsStable["host.pkgsStable"]
        pkgsUnstable["host.pkgsUnstable"]
        inputs["inputs + self + nixgl"]
        hostConfig["hostConfig"]
    end
    nixSet --> merged["homeManagerConfiguration"]
    baseModule --> merged
    generic --> merged
    style M fill:#e3f2fd
```

### NixOS Host — Home Manager Integration

When `isNixOS = true`, home-manager runs inside NixOS via `home-manager.users`. Each user gets a module chain built by `mkUserHomeModule`:

```mermaid
flowchart LR
    subgraph HM["Per-user HM chain (mkUserHomeModule)"]
        homeFeat["host.homeModules\n(resolved home features)"]
        hostMod["resolveHostModules host 'home'\n(host-local home modules)"]
        perUser["host.homeModules.<user>\n(e.g. home-<user>.nix)"]
        unfree["unfreeOptionsModule"]
        hmFlakeMod["self.flakeModules.home-manager"]
        defaults["home.username + home.homeDirectory"]
    end
    homeFeat --> chain["lib.flatten → imports"]
    hostMod --> chain
    perUser --> chain
    unfree --> chain
    hmFlakeMod --> chain
    defaults --> chain
    style HM fill:#e8f5e9
```

---

## Data Flow Summary

```mermaid
graph LR
    subgraph Static ["Static (builtins.readDir)"]
        hosts["hosts/ directory"]
        features["features/ directory"]
    end

    subgraph Lib ["lib/ (evaluation time)"]
        featLib["lib/features.nix\n→ discoveredFeatures map"]
        bldLib["lib/builders.nix\nmkHostContext → pkgsStable +\npkgsUnstable + nixosModules +\nhomeModules + allUnfree\n+ homeOverlays\n+ NixOS/HM build fns"]
    end

    subgraph Disc ["modules/discovery.nix"]
        disc["discoverHosts\n→ {host: {system, isNixOS, osUsernames,\n hmUsernames, features, modules}}"]
    end

    hosts --> disc
    features --> featLib

    disc --> bldLib
    featLib --> bldLib

    bldLib --> nixosOut["nixosConfigurations"]
    bldLib --> hmOut["homeConfigurations"]

    style Static fill:#f5f5f5
    style Lib fill:#e8f5e9
    style Disc fill:#e1f5fe
    style Builders fill:#c8e6c9
```

---

## Key Design Decisions

| Decision                                     | Rationale                                                                                                                                                                                                                                                                                         |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `isNixOS` boolean in host schema             | Simple, explicit classification — `true` → NixOS host, `false` → HM-only                                                                                                                                                                                                                          |
| `system` read from host file                 | `discovery.nix` validates `system` via host-schema; used for `pkgs` resolution                                                                                                                                                                                                                    |
| Flat host files + directory hosts            | Single `hosts/<name>.nix` for simple hosts; directory hosts auto-discover `nixos.nix`, `shared.nix`, `home-<user>.nix` from the directory                                                                                                                                                         |
| Feature modules auto-discovered              | `lib/features.nix` scans `features/` at evaluation time — no manual registration needed                                                                                                                                                                                                           |
| Host context + builders consolidated         | `lib/builders.nix` handles both pkgs creation (`mkHostContext`) and configuration building (`buildNixosConfigurations`, `buildHomeConfigurations`). Unfree/overlays extracted via targeted `evalModules` with `_module.check = false` — all mkPkgs, overlays, and unfree logic lives in one file. |
| `lib/` is pure functions                     | Nothing in `lib/` has `options`, `config`, or `imports` at the top level. Everything is importable without side effects                                                                                                                                                                           |
| `modules/` wires the system                  | Flake-parts modules, NixOS/HM modules, and discovery logic live here — they contribute to the module system                                                                                                                                                                                       |
| Two builders, same file                      | `buildNixosConfigurations` and `buildHomeConfigurations` both live in `lib/builders.nix` alongside `mkHostContext`. NixOS and HM have different output targets and pkgs wiring, but sharing the imports/helpers reduces duplication.                                                              |
| `flakeModules` for reusable modules          | `modules/nixos.nix` and `modules/home-manager.nix` are exposed as flake modules, usable by other flakes or imported directly                                                                                                                                                                      |
| `nix-settings.nix` shared across all configs | Injected into every NixOS and Home Manager configuration to ensure consistent nix settings and cachix substituters                                                                                                                                                                                |
| Separate `pkgs` / `pkgsUnstable`             | `mkPkgs` called with `nixpkgs` for stable, `nixpkgs-unstable` for unstable; each with its own `allowUnfreePredicate`                                                                                                                                                                              |
| `hmEnabled` per-user toggle                  | `users.<name>.hmEnabled = false` creates the NixOS system user but skips loading their home-manager module                                                                                                                                                                                        |
| `home-manager` inside NixOS vs standalone    | NixOS hosts embed home-manager via `home-manager.users`; HM-only hosts get standalone `homeManagerConfiguration`                                                                                                                                                                                  |
