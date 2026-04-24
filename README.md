# flakeroot — Unified Nix (Linux/Darwin) & Home Manager Configuration

A **flake-driven**, host-discovering config system for NixOS, macOS (darwin), and Home Manager — all from one repository.

## Quick Start

### Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled (`nix-command` + `flakes`)
- `$USER` and `$HOST` (or `/etc/hostname` on Linux) set in your environment

### Switching Configurations

| Tool                                               | Command                                      | Use Case                                   |
| -------------------------------------------------- | -------------------------------------------- | ------------------------------------------ |
| **[nh](https://github.com/nhdb/nh)** (recommended) | `nh os switch`                               | NixOS system + HM                          |
|                                                    | `nh darwin switch`                           | Darwin system + HM                         |
|                                                    | `nh home switch`                             | Home Manager only (auto-detects user@host) |
| **home-manager**                                   | `home-manager switch --flake . --impure`     | Auto-detects `$HOST` + `$USER`             |
| **nixos-rebuild**                                  | `nixos-rebuild switch --flake .#<hostname>`  | NixOS system only                          |
| **darwin-rebuild**                                 | `darwin-rebuild switch --flake .#<hostname>` | Darwin system only                         |

### Dry-Run & Inspect

```bash
# List all available configurations
nix flake show

# Preview what would be built (no activation)
nix build .#homeConfigurations."<user>@<host>".activationPackage --dry-run
nix build .#nixosConfigurations."<host>".activationPackage --dry-run

# Show the resulting store path without building
nix build .#homeConfigurations."<user>@<host>".activationPackage --no-link --print-out-paths

# Inspect a specific config's derivation
nix build .#homeConfigurations."<user>@<host>".activationPackage -L 2>&1 | head
```

### Cleanup & Maintenance

```bash
# Garbage-collect old generations (nh manages this automatically)
nh cleanup --keep 5 --keep-since 7d

# List current generations
nh os list
nh home list

# Switch to a specific past generation
nh os switch --rollback
nh home switch --rollback
```

## Architecture

```
modules/
├── core/
│   ├── default.nix          # Entry: imports discovery + builders, exposes coreModules
│   ├── discovery.nix        # Scans modules/hosts/<name>/ → {system, hasSystem, users}
│   └── builders.nix         # mkSystem (NixOS/darwin), mkHome (HM), buildConfigs (foldlAttrs)
├── nixos/
│   └── default.nix          # Base NixOS: unfree, user groups, stateVersion
├── darwin/
│   └── default.nix          # Base Darwin: shells (zsh/fish), TouchID sudo, stateVersion
├── home-manager/
│   ├── default.nix          # Re-exports base + dev
│   ├── base.nix             # CLI tools, editors, shells, direnv, nh
│   ├── dev.nix              # Nix dev tools (alejandra, nil, cachix, uv, ruff, etc.)
│   └── gpg.nix              # Optional: GPG agent with SSH support
└── hosts/
    ├── methyl-bazzite/      # NixOS host (x86_64-linux)
    │   ├── default.nix      # system = "x86_64-linux"
    │   └── home-<user>.nix  # HM for the user (base + gpg)
    └── propyl/              # Darwin host (x86_64-darwin)
        ├── default.nix      # system = "x86_64-darwin"
        ├── system.nix       # Darwin system config (fish, neovim, fonts, etc.)
        └── home-<user>.nix    # HM for the user (base only)
```

### How Host Discovery Works

1. `discovery.nix` scans `modules/hosts/` for directories
2. Each directory's `default.nix` is imported to read `system` (defaults to `x86_64-linux`)
3. Files matching `home-*.nix` are parsed for usernames
4. Presence of `system.nix` determines if the host is a full system config or HM-only
5. `system` ending in `darwin` → Darwin; otherwise → NixOS

### Configuration Composition

**NixOS / Darwin host** (has `system.nix`):

```
coreModules → home-manager module → hmDefaults → system.nix → platformModule
```

**Home Manager config** (`<user>@<host>`):

```
coreModules → home-<user>.nix → defaults (username, homeDirectory, nixpkgs.system)
```

## Flake Outputs

| Output                               | Description                                                    | Example                            |
| ------------------------------------ | -------------------------------------------------------------- | ---------------------------------- |
| `homeConfigurations."<user>@<host>"` | Per user-host Home Manager config                              | `homeConfigurations.<user>@<host>` |
| `homeConfigurations.default`         | Auto-inferred from `$HOST` + `$USER` (if matching pair exists) | `homeConfigurations.default`       |
| `nixosConfigurations.<host>`         | NixOS system config (Linux + `system.nix` only)                | `nixosConfigurations.<hostname>`   |
| `darwinConfigurations.<host>`        | Darwin system config (Darwin + `system.nix` only)              | `darwinConfigurations.<hostname>`  |

## Adding a New Host

Create `modules/hosts/<name>/` with at minimum a `default.nix`:

```nix
# modules/hosts/myhost/default.nix
{
  system = "x86_64-linux";  # or "aarch64-darwin", "aarch64-linux", etc.
}
```

### Home Manager–Only Host

```nix
# modules/hosts/myhost/home-<user>.nix
{pkgs, ...}: {
  imports = [ ../../home-manager ];
  # imports = [ ../../home-manager/gpg.nix ];  # add GPG agent if needed
}
```

### Full NixOS / Darwin Host

Add `system.nix` alongside `home-<user>.nix`:

```nix
# modules/hosts/myhost/system.nix
{ pkgs, username, ... }:
{
  imports = [ ../../nixos ];  # or ../../darwin for macOS
  environment.systemPackages = with pkgs; [ git neovim ];
}

# modules/hosts/myhost/home-<user>.nix
{ pkgs, ... }:
{
  imports = [ ../../home-manager ];
}
```

> **Note:** The `system` attribute in `default.nix` determines host type: `*-darwin` → Darwin, else NixOS. `system.nix` is imported directly as a NixOS/Darwin module — it receives `{ pkgs, username, ... }` as special args, not `{ system, module }`.

## Supported Platforms

| Platform         | NixOS | Darwin | Home Manager |
| ---------------- | ----- | ------ | ------------ |
| `x86_64-linux`   | ✅    | —      | ✅           |
| `aarch64-linux`  | ✅    | —      | ✅           |
| `x86_64-darwin`  | —     | ✅     | ✅           |
| `aarch64-darwin` | —     | ✅     | ✅           |

> **macOS (Darwin) / Home Manager:** On Darwin systems, use `nh darwin switch` for full system + Home Manager configuration, or `nh home switch` for Home Manager only. Home Manager works independently on both Linux and Darwin regardless of the host's `system` attribute.

## Importing from Other Flakes

This flake exports `homeConfigurations`, `nixosConfigurations`, and `darwinConfigurations` — not a reusable module set. To consume a host config from another flake:

```nix
inputs.myhost = { url = "github:you/flakeroot"; };

# Re-export a home-manager config from another flakeroot host
homeConfigurations.myuser = inputs.home-manager.lib.homeManagerConfiguration {
  modules = [ inputs.myhost.homeConfigurations.otheruser@otherhost.config ];
};
```

## Core Settings (Applied to All Configs)

- **Unfree packages:** allowed
- **Substituters:** cache.nixos.org, wombatfromhell.cachix.org, nix-community.cachix.org, cache.lix.systems
- **Prompt:** `(nix:$name)` when inside a derivation
- **Experimental features:** `nix-command`, `flakes`

## See Also

- [DESIGN.md](./DESIGN.md) — Full architecture, dependency graph, and build pipeline diagrams
