# DESIGN — Architecture & Dependencies

## Module Dependency Graph

Static import relationships between all module files.

```mermaid
graph TB
    subgraph Entry ["Flake Entry"]
        flake["flake.nix\nflake-parts + imports ./modules"]
    end

    subgraph Mods ["modules/"]
        modsDefault["modules/default.nix\nexposes flakeModules\nnixos + home-manager"]
        core["modules/core/default.nix\nimports builders + features"]
    end

    subgraph Core ["Core Infrastructure"]
        disc["modules/core/discovery.nix\nreadDir hosts/ → discoveredHosts"]
        nixosB["modules/core/builders/nixos.nix\nfilter NixOS hosts → nixosConfigurations"]
        hmB["modules/core/builders/home-manager.nix\nfilter HM-only hosts → homeConfigurations"]
        shared["modules/core/builders/shared.nix\nresolveHostModules + resolveFeatures +\nmkUserHomeModule + unfree collection"]
        feat["modules/core/features.nix\ndiscoverFeatures + resolve modules"]
        schema["modules/core/host-schema.nix\nvalidation schema for host files"]
        pkgs["modules/core/pkgs.nix\nmkPkgs + mkUnfreeOptionsModule"]
        nixSettings["modules/core/nix-settings.nix\nsubstituters + trusted keys + nix.package"]
    end

    subgraph HMMod ["hm flake module"]
        hmMod["modules/home-manager/default.nix\nstateVersion + nh + manual"]
    end

    subgraph NixOSMod ["nixos flake module"]
        nixOSMod["modules/nixos/default.nix\nstateVersion + fish + user shells"]
    end

    subgraph Features ["Feature Modules (discovered)"]
        hmBase["modules/features/hm-base/home.nix\nCLI utilities"]
        hmDev["modules/features/hm-dev/home.nix\nDev tooling + direnv"]
        hmGpg["modules/features/hm-gpg/home.nix\ngpg-agent + SSH support"]
        hmMedia["modules/features/hm-media/home.nix\nyt-dlp"]
    end

    subgraph Hosts ["Host Configs (discovered)"]
        hostFiles["hosts/*.nix\nflat .nix files: {system, username, isNixOS, features, modules}"]
    end

    flake --> modsDefault
    modsDefault --> core

    core --> disc
    core --> nixosB
    core --> hmB
    core --> feat

    nixosB --> disc
    nixosB --> shared
    nixosB --> feat
    nixosB --> pkgs

    hmB --> disc
    hmB --> shared
    hmB --> feat
    hmB --> pkgs

    shared --> feat
    shared --> pkgs

    disc --> schema

    hmMod --> pkgs
    nixOSMod --> pkgs

    style Core fill:#e1f5fe
    style HMMod fill:#f3e5f5
    style NixOSMod fill:#f3e5f5
    style Features fill:#fff3e0
    style Hosts fill:#fff9c4
```

## Build Pipeline

Runtime evaluation flow from flake entry point to final configurations.

```mermaid
flowchart LR
    subgraph E ["Entry: flake.nix"]
        fp["flake-parts.lib.mkFlake\nimports ./modules"]
    end

    subgraph M ["modules/default.nix"]
        fm["exposes flake.flakeModules\n.nixos → ./modules/nixos\n.home-manager → ./modules/home-manager"]
    end

    subgraph C ["modules/core/default.nix"]
        cCore["imports builders + features\nexposes flake.features"]
    end

    subgraph D ["Discovery (discovery.nix)"]
        scan["readDir hosts/"]
        importHost["import each host/*.nix"]
        validate["evalModules against host-schema"]
        enrich["derive osUsernames + hmUsernames + extract modules"]
    end

    subgraph N ["NixOS Builder (nixos.nix)"]
        filter["filter: isNixOS == true"]
        resolveN["resolve features → nixos"]
        buildN["nixpkgs.lib.nixosSystem\nmodules: nix-settings + nixos-module\n+ features + host + hm + defaults"]
    end

    subgraph H ["HM Builder (home-manager.nix)"]
        filterH["filter: isNixOS == false"]
        resolveH["resolve features → home"]
        buildH["homeManagerConfiguration\nmodules: nix-settings + hm-module\n+ features + host + defaults"]
    end

    fp --> fm
    fm --> cCore

    cCore --> D
    cCore --> N
    cCore --> H

    scan --> importHost --> validate --> enrich

    filter --> resolveN --> buildN
    filterH --> resolveH --> buildH

    style C fill:#e1f5fe
    style N fill:#c8e6c9
    style H fill:#c8e6c9
```

## Host Type Resolution

A host file is classified by its `isNixOS` field.

```mermaid
flowchart TD
    Start(["hosts/<name>.nix"]) --> read["import file"]
    read --> schema["validate against host-schema"]
    schema --> isNixOS{"isNixOS == true?"}

    isNixOS -->|yes| nixosHost["NixOS host"]
    isNixOS -->|no| hmOnly["Home Manager–only host"]

    nixosHost --> nixosOut["nixosConfigurations.<name>\n+ homeConfigurations.<user>@<name>"]
    hmOnly --> hmOut["homeConfigurations.<user>@<name>"]

    style nixosHost fill:#c8e6c9,stroke:#333
    style hmOnly fill:#fff9c4,stroke:#333
```

## Feature System

Features are auto-discovered from `modules/features/<name>/` directories. Each feature directory contains platform-tagged `.nix` files (e.g., `home.nix`, `nixos.nix`). Known features that lack a module for the requested platform are silently skipped (e.g. HM-only features in a NixOS host); unknown features throw a descriptive error from `featuresLib.resolve`.

```mermaid
flowchart LR
    subgraph Discover ["Discovery (features.nix)"]
        scan["readDir modules/features/"]
        map["map → {<feature>: {<platform>: path}}"]
    end

    subgraph Resolve ["Resolution (resolve featureList → platform)"]
        validate["validate: assert known feature + attrPath\nthrow on unknown feature or missing platform"]
        dryEval["evalModules to extract unfree lists"]
        return["return { modules: paths, unfree }"]
    end

    subgraph Usage ["Builder Usage"]
        nixosFeat["nixos.nix: resolve features → nixos"]
        hmFeat["home-manager.nix: resolve features → home"]
    end

    scan --> map

    validate --> dryEval --> return

    nixosFeat --> validate
    hmFeat --> validate

    style Discover fill:#e3f2fd
    style Resolve fill:#fff3e0
    style Usage fill:#e8f5e9
```

## Configuration Composition

### NixOS Host

```mermaid
flowchart LR
    subgraph M["Modules (merged via lib.flatten)"]
        nixSet["nix-settings.nix\n(substituters, trusted keys, nix.package)"]
        nixosMod["flakeModules.nixos\n(stateVersion, fish, user shells)"]
        autoUser["mkNixosUserModule\n(genAttrs osUsernames → users.users)"]
        featMod["resolved nixos feature modules"]
        hostMod["host-specific nixos modules (host.modules.nixos)"]
        hmMod["home-manager.nixosModules.home-manager"]
        hmCfg["home-manager config\n(genAttrs hmUsernames →\n per-user modules + defaults)"]
    end
    subgraph SA["specialArgs"]
        inputs["flake inputs"]
        self["self"]
        osUsernames["host.osUsernames"]
        hmUsernames["host.hmUsernames"]
    end
    nixSet --> merged["Modules (merged)"]
    nixosMod --> merged
    autoUser --> merged
    featMod --> merged
    hostMod --> merged
    hmMod --> merged
    hmCfg --> merged
    inputs --> merged
    self --> merged
    osUsernames --> merged
    hmUsernames --> merged
    style M fill:#e3f2fd
```

### Home Manager–Only Host

```mermaid
flowchart LR
    subgraph M["Modules (merged via lib.flatten)"]
        nixSet["nix-settings.nix"]
        hmMod["flakeModules.home-manager\n(stateVersion, nh, manual, programs)"]
        featMod["resolved home feature modules"]
        hostMod["host-specific HM modules (host.modules.home)"]
        userMod["home-<user>.nix (if exists)"]
        defaults["defaults via imports\n(mkUserHomeModule + targets.genericLinux.enable)"]
    end
    subgraph EA["extraSpecialArgs"]
        pkgsUnstable["pkgsUnstable"]
        inputs["flake inputs"]
        self["self"]
        hmUsernames["host.hmUsernames"]
        pkgsStable["pkgsStable (stable pkgs)"]
    end
    nixSet --> merged
    hmMod --> merged
    featMod --> merged
    hostMod --> merged
    userMod --> merged
    defaults --> merged
    pkgsUnstable --> merged
    inputs --> merged
    self --> merged
    hmUsernames --> merged
    pkgsStable --> merged
    style M fill:#e3f2fd
```

### NixOS Host Home Manager Integration

When `isNixOS = true`, home-manager is configured **inside** the NixOS system via `home-manager.users` with per-user module chains:

```mermaid
flowchart LR
    subgraph HM["Per-user HM chain"]
        unfreeMod["unfreeOptionsModule"]
        hmMod2["flakeModules.home-manager"]
        featMod2["resolved home feature modules"]
        hostHm["host.modules.home"]
        userHm["home-<user>.nix"]
        defaultsHM["defaults\n(home.username, /home/<user>)"]
    end
    unfreeMod --> chain["HM chain"]
    hmMod2 --> chain
    featMod2 --> chain
    hostHm --> chain
    userHm --> chain
    defaultsHM --> chain
    style HM fill:#e8f5e9
```

## Data Flow Summary

```mermaid
graph LR
    subgraph Static ["Static (builtins.readDir)"]
        hosts["hosts/ directory"]
        features["modules/features/ directory"]
    end

    subgraph Eval ["Evaluation time"]
        disc["discoverHosts\n→ &#123;<host>: &#123;system, isNixOS, osUsernames, hmUsernames,\n features, modules&#125;&#125;"]
        buildN["nixos.nix: filter + resolve + nixosSystem"]
        buildH["home-manager.nix: filter + resolve + homeManagerConfiguration"]
    end

    hosts --> disc
    features --> disc

    disc --> buildN
    disc --> buildH

    buildN --> nixosOut["nixosConfigurations"]
    buildH --> hmOut["homeConfigurations"]

    style Static fill:#f5f5f5
    style Eval fill:#e3f2fd
```

## Key Design Decisions

| Decision                                     | Rationale                                                                                                                                   |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `isNixOS` boolean in host schema             | Simple, explicit classification — `true` → NixOS host, `false` → HM-only                                                                    |
| `system` read from host file                 | `discovery.nix` validates `system` via host-schema; used for `pkgs` resolution                                                              |
| Flat host files (not directories)            | Single `hosts/<name>.nix` file per host; no need for `default.nix` in each host                                                             |
| Feature modules auto-discovered              | `features.nix` scans `modules/features/` at evaluation time — no manual registration needed                                                 |
| Unfree extraction via dry eval               | Features and user modules are evaluated in isolation to extract `unfree` lists before `pkgs` is available, preventing circular dependencies |
| `flakeModules` for reusable modules          | `modules/nixos/` and `modules/home-manager/` are exposed as flake modules, usable by other flakes or imported directly                      |
| `nix-settings.nix` shared across all configs | Injected into every NixOS and Home Manager configuration to ensure consistent nix settings and cachix substituters                          |
| Separate `pkgs` / `pkgsUnstable`             | `mkPkgs` called with `nixpkgs` for stable, `mkUnstablePkgs` via `nixpkgs-unstable` for unstable; each with its own `allowUnfreePredicate`   |
| `hmEnabled` per-user toggle                  | `users.<name>.hmEnabled = false` creates the NixOS system user but skips loading their home-manager module                                  |
| `home-manager` inside NixOS vs standalone    | NixOS hosts embed home-manager via `home-manager.users`; HM-only hosts get standalone `homeManagerConfiguration`                            |
