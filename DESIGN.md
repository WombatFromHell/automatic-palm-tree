# DESIGN — Architecture & Dependencies

## Module Dependency Graph

Static import relationships between all module files.

```mermaid
graph TB
    subgraph Inputs ["Flake Inputs"]
        nixpkgs["nixpkgs"]
        hm["home-manager"]
        darwin["nix-darwin"]
        fp["flake-parts"]
    end

    subgraph Core ["Core Infrastructure"]
        coreDef["core/default.nix"]
        disc["core/discovery.nix"]
        build["core/builders.nix"]
        coreMod["coreModule (inline)"]
    end

    subgraph BaseM["Base Modules"]
        nixosMod["nixos/default.nix"]
        darwinMod["darwin/default.nix"]
        hmDef["home-manager/default.nix"]
        hmBase["home-manager/base.nix"]
        hmDev["home-manager/dev.nix"]
        hmGpg["home-manager/gpg.nix"]
    end

    subgraph Hosts ["Host Configs (per directory)"]
        sysNix["system.nix"]
        homeNix["home-<user>.nix"]
    end

    nixpkgs --> build
    hm --> build
    darwin --> build
    fp --> flakeEntrypoint

    coreDef --> disc
    coreDef --> build
    coreDef --> coreMod

    hmDef --> hmBase
    hmDef --> hmDev

    sysNix -.-> darwinMod
    sysNix -.-> nixosMod
    homeNix -.-> hmDef
    homeNix -.-> hmGpg

    style Core fill:#e1f5fe
    style BaseM fill:#f3e5f5
    style Hosts fill:#fff3e0
```

## Build Pipeline

Runtime evaluation flow from flake entry point to final configurations.

```mermaid
flowchart LR
    subgraph E ["Entry: flake.nix"]
        fp["flake-parts.lib.mkFlake"]
        core["core/default.nix"]
        hostsDir["./modules/hosts/"]
        ss["supportedSystems\n[x86_64-linux, aarch64-darwin, aarch64-linux]"]
    end

    subgraph D ["Discovery Phase"]
        disc["discoverHosts\n(scans hostsDir)"]
        hInfo{"Host info:\n{hasSystem, users, platform}"}
    end

    subgraph B ["Build Phase (per system)"]
        filter["filterBySystem\n(platform == system)"]
        partition["partitionHosts\n→ systemHosts | homeHosts"]
        mkNixos["mkNixos\n(nixpkgs.lib.nixosSystem)"]
        mkDarwin["mkDarwin\n(nix-darwin.darwinSystem)"]
        mkHome["mkHome\n(homeManagerConfiguration)"]
    end

    subgraph O ["Outputs"]
        nixosOut["nixosConfigurations"]
        darwinOut["darwinConfigurations"]
        homeOut["homeConfigurations"]
        autoDef["autoDefault\n($HOSTNAME + $USER)"]
    end

    fp --> core
    core --> disc
    hostsDir --> disc
    ss --> B

    disc --> hInfo
    hInfo --> filter
    filter --> partition

    partition -.->|systemHosts + Linux| mkNixos
    partition -.->|systemHosts + Darwin| mkDarwin
    partition -.->|homeHosts| mkHome

    mkNixos --> nixosOut
    mkDarwin --> darwinOut
    mkHome --> homeOut

    homeOut --> autoDef
```

## Host Type Resolution

How a host directory is classified into NixOS, Darwin, or Home Manager–only.

```mermaid
flowchart TD
    Start(["host/"]) --> readDir["readDir"]
    readDir --> hasSys{"system.nix exists?"}

    hasSys -->|yes| getSysPlat["import system.nix → .platform / .system"]
    hasSys -->|no| getHomePlat["scan home-*.nix files"]

    getSysPlat --> platFound{".platform or\n.system defined?"}
    platFound -->|yes| finalPlat["use platform value"]
    platFound -->|no| defaultPlat["default: x86_64-linux"]

    getHomePlat --> hasUsers{"any home-*.nix?"}
    hasUsers -->|yes| getFirstUser["import first home-*.nix → .platform / .system"]
    getFirstUser --> platFound2{".platform or\n.system defined?"}
    plat2_yes["yes"] --> finalPlat
    plat2_no["no"] --> defaultPlat

    hasUsers -->|no| defaultHome["default: x86_64-linux"]

    finalPlat --> classify{"platform ends with\n'darwin'?"}
    classify -->|yes| darwinHost["Darwin host"]
    classify -->|no| linuxHost["NixOS or HM-only host"]

    darwinHost --> hasSys2{"system.nix exists?"}
    hasSys2 -->|yes| fullDarwin["darwinConfigurations.<host>"]
    hasSys2 -->|no| hmOnlyDarwin["homeConfigurations only (HM on Darwin)"]

    linuxHost --> hasSys3{"system.nix exists?"}
    hasSys3 -->|yes| fullLinux["nixosConfigurations.<host>"]
    hasSys3 -->|no| hmOnlyLinux["homeConfigurations only (standalone HM)"]

    style darwinHost fill:#f9a825,stroke:#333,color:#000
    style fullDarwin fill:#c8e6c9,stroke:#333
    style fullLinux fill:#c8e6c9,stroke:#333
    style hmOnlyDarwin fill:#fff9c4,stroke:#333
    style hmOnlyLinux fill:#fff9c4,stroke:#333
```

## Configuration Composition

How modules are merged for each configuration type.

### NixOS Host

```mermaid
flowchart LR
    subgraph M["Modules (merged in order)"]
        coreMod1["coreModule\n(nix settings, prompt, substituters)"]
        sysMod["system.nix.module\n(host-specific options)"]
        platMod["mkPlatformModule\n(networking.hostName, nixpkgs.hostPlatform)"]
    end
    subgraph SA["specialArgs"]
        self["self"]
        inputs["flake inputs"]
    end
    coreMod1 --> final
    sysMod --> final
    platMod --> final
    self --> final
    inputs --> final
    style M fill:#e3f2fd
```

### Darwin Host

Same as NixOS, plus:

- `inputs.home-manager.darwinModules.home-manager` inserted after system module
- All other modules identical

### Home Manager Config (`<user>@<host>`)

```mermaid
flowchart LR
    subgraph M2["Modules (merged in order)"]
        coreMod2["coreModule\n(nix settings, prompt, substituters)"]
        homeHost["home-<user>.nix\n(host-specific HM options)"]
        defaults["implicit defaults:\n  home.username = <user>\n  nixpkgs.system = <system>\n  nix.package = pkgs.nix"]
    end
    subgraph SA2["extraSpecialArgs"]
        self2["self"]
        inputs2["flake inputs"]
        hostname2["hostname = <host>"]
    end
    coreMod2 --> final2
    homeHost --> final2
    defaults --> final2
    self2 --> final2
    inputs2 --> final2
    hostname2 --> final2
    style M2 fill:#e3f2fd
```

## Data Flow Summary

```mermaid
graph LR
    subgraph Static ["Static (builtins.readDir)"]
        hosts["modules/hosts/ directory tree"]
    end

    subgraph Eval ["Evaluation time"]
        disc["discoverHosts\n→ {<host>: {hasSystem, users, platform}}"]
        part["partition by system →\n{systemHosts, homeHosts}"]
        build["buildAllConfigs\n→ {nixos, darwin, home}"]
    end

    subgraph Runtime ["Runtime (env vars)"]
        env["$HOSTNAME", "$USER"]
        auto["autoDefault\n→ homeConfigurations.default"]
    end

    hosts --> disc
    disc --> part
    part --> build
    env --> auto
```

## Key Design Decisions

| Decision                                                   | Rationale                                                                                                                         |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `platform` preferred over `system` in discovery            | Avoids collision with NixOS `system.*` options; falls back to `system` attr for backwards compat                                  |
| Lazy `module` function in `system.nix`                     | Defers `pkgs` evaluation until the builder phase, giving access to the correct system's packages                                  |
| Platform detection cascades: system > first home > default | A host without `system.nix` can still declare its platform via any `home-*.nix`, keeping standalone HM hosts flexible             |
| `autoDefault` uses env vars at export time                 | Enables `home-manager switch --flake .` without specifying a config key, but only when the current user/host matches a known pair |
| Home Manager built for all hosts (even system hosts)       | Allows per-user configs alongside full system management; Darwin always includes home-manager module                              |
