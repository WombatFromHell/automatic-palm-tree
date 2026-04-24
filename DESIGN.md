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
        coreMod["coreModules\n(nix settings: experimental features, prompt, substituters, trusted keys)"]
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
    fp --> coreDef

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
        core["core/default.nix\n(imports discovery + builders)"]
        hostsDir["./modules/hosts/"]
    end

    subgraph D ["Discovery Phase"]
        disc["discoverHosts\n(scans hostsDir, reads default.nix per host)"]
        hInfo{"Host info:\n{hasSystem, users, system}"}
    end

    subgraph B ["Build Phase"]
        buildConfigs["buildConfigs\n(foldlAttrs → nixos | darwin | home)"]
        mkNixos["mkSystem → nixpkgs.lib.nixosSystem\n(or nix-darwin.darwinSystem)"]
        mkHome["mkHome\n(homeManagerConfiguration)"]
    end

    subgraph O ["Outputs"]
        nixosOut["nixosConfigurations"]
        darwinOut["darwinConfigurations"]
        homeOut["homeConfigurations"]
        autoDef["autoDefault\n($HOST + $USER)"]
    end

    core --> disc
    hostsDir --> disc

    disc --> hInfo
    hInfo --> buildConfigs

    buildConfigs -.->|Linux + hasSystem| mkNixos
    buildConfigs -.->|Darwin + hasSystem| mkNixos
    buildConfigs -.->|all hosts with users| mkHome

    mkNixos --> nixosOut
    mkNixos --> darwinOut
    mkHome --> homeOut

    homeOut --> autoDef
```

## Host Type Resolution

How a host directory is classified into NixOS, Darwin, or Home Manager–only.

```mermaid
flowchart TD
    Start(["host/"]) --> readDir["readDir hosts/<name>/"]
    readDir --> readMeta["import default.nix → meta"]
    readMeta --> hasMeta{"meta.system defined?"}
    hasMeta -->|yes| finalSys["use meta.system"]
    hasMeta -->|no| defaultSys["default: x86_64-linux"]

    finalSys --> classify{"system ends with\n'darwin'?"}
    classify -->|yes| darwinHost["Darwin host"]
    classify -->|no| linuxHost["NixOS or HM-only host"]

    darwinHost --> hasSys{"system.nix exists?"}
    hasSys -->|yes| fullDarwin["darwinConfigurations.<host>\n+ homeConfigurations.*"]
    hasSys -->|no| hmOnlyDarwin["homeConfigurations only"]

    linuxHost --> hasSys2{"system.nix exists?"}
    hasSys2 -->|yes| fullLinux["nixosConfigurations.<host>\n+ homeConfigurations.*"]
    hasSys2 -->|no| hmOnlyLinux["homeConfigurations only (standalone HM)"]

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
        coreMod1["coreModules\n(nix settings: experimental features, prompt, substituters, trusted keys)"]
        hmMod1["home-manager module\n(inputs.home-manager.nixosModules.home-manager)"]
        hmDef1["hmDefaults\n(home-manager.users → per-user home-*.nix imports)"]
        sysMod["system.nix\n(host-specific options, as module)"]
        platMod["platformModule\n(networking.hostName, nixpkgs.hostPlatform)"]
    end
    subgraph SA["specialArgs"]
        self["self"]
        inputs["flake inputs"]
        username["username = head(users)"]
    end
    coreMod1 --> final
    hmMod1 --> final
    hmDef1 --> final
    sysMod --> final
    platMod --> final
    self --> final
    inputs --> final
    style M fill:#e3f2fd
```

### Darwin Host

Same as NixOS, plus:

- `inputs.home-manager.darwinModules.home-manager` used in `hmMod` (vs `nixosModules` on Linux)
- `hmDefaults` (home-manager.users → per-user home-\*.nix imports) applied when `users != []`
- `hmDarwinDefaults` (`users.users.<user>.home = "/Users/<user>"`) applied only when `darwin && users != []`
- All other modules identical

### Home Manager Config (`<user>@<host>`)

```mermaid
flowchart LR
    subgraph M2["Modules (merged in order)"]
        coreMod2["coreModules\n(nix settings: experimental features, prompt, substituters, trusted keys)"]
        homeHost["home-<user>.nix\n(host-specific HM options)"]
        defaults["implicit defaults:\n  home.username = <user>\n  home.homeDirectory = /Users/<user> (Darwin)\n                         /home/<user> (Linux)\n  nixpkgs.system = <system>\n  nix.package = pkgs.nix"]
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
        disc["discoverHosts\n→ {<host>: {hasSystem, users, system}}"]
        build["buildConfigs\n(foldlAttrs → {nixos, darwin, home})"]
    end

    subgraph Eval2 ["Evaluation time (env vars / file)"]
        env["hostname = /etc/hostname > $HOST\nusername = $USER"]
        auto["autoDefault\n→ homeConfigurations.default"]
    end

    hosts --> disc
    disc --> build
    env --> auto
```

## Deployment with nh (nhctl)

This flake is designed to work seamlessly with [nh (nhctl)](https://github.com/nhdb/nh). The `nh` client provides the following subcommands for interacting with this flake:

| Subcommand         | Purpose                                                                |
| ------------------ | ---------------------------------------------------------------------- |
| `nh os switch`     | Build and activate NixOS system configuration                          |
| `nh darwin switch` | Build and activate Darwin system configuration                         |
| `nh home switch`   | Build and activate Home Manager configuration (auto-detects user@host) |

`nh` handles evaluation, building, and activation in a single command, and automatically discovers the appropriate configuration based on the current host and user. It is the preferred way to interact with this flake.

## Key Design Decisions

| Decision                                                     | Rationale                                                                                                                                                          |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `system` read from `default.nix` in discovery                | `discoverHosts` reads `meta.system` directly from each host's `default.nix`, falling back to `x86_64-linux` if undefined                                           |
| `system.nix` imported as a module (not `{ system, module }`) | `mkSystem` imports `system.nix` directly as a NixOS/Darwin module; `system` is inherited from `default.nix` via `inherit system`                                   |
| `autoDefault` uses env vars at evaluation time               | Enables `home-manager switch --flake .` without specifying a config key, but only when the current user/host matches a known pair                                  |
| Home Manager built for all hosts with users                  | `mkHome` runs for every user in every host; both NixOS and Darwin system configs include the home-manager module with per-user configs merged via `hmCommon.users` |
