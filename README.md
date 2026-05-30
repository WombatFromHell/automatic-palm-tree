# flakeroot — Unified Nix & Home Manager Configuration

A **flake-driven**, host-discovering config system for NixOS and Home Manager — all from one repository.

## Quick Start

### Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled (`nix-command` + `flakes`)
- `$USER` and `$HOST` (or `/etc/hostname` on Linux) set in the environment

### Switching Configurations

| Tool                                               | Command                                     | Use Case                                              |
| -------------------------------------------------- | ------------------------------------------- | ----------------------------------------------------- |
| **[nh](https://github.com/nhdb/nh)** (recommended) | `nh os switch`                              | NixOS system + HM                                     |
|                                                    | `nh home switch`                            | Home Manager only (auto-detects user@host)            |
| **home-manager**                                   | `home-manager switch --flake . --impure`    | Auto-detects `$HOST` + `$USER`                        |
| **nixos-rebuild**                                  | `nixos-rebuild switch --flake .#<hostname>` | NixOS system only (requires an `isNixOS = true` host) |

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
hosts/
├── methyl-bazzite.nix    # Flat host file: system, username, isNixOS, features, modules
├── family-desktop/       # [illustrative] Multi-user host directory
│   ├── default.nix       # Barrel loader: system, users attrset, features, module imports
│   ├── nixos.nix         # NixOS system config + user account definitions
│   ├── shared.nix        # Shared between NixOS and HM contexts
│   ├── home-mainuser.nix # Home Manager module for mainuser (plain HM module)
│   └── home-anotheruser.nix
└── ...

modules/
├── core/
│   ├── default.nix       # Entry: imports discovery + builders, exposes flake.features
│   ├── discovery.nix     # Scans hosts/ for .nix files → validates against schema
│   ├── host-schema.nix   # Strict schema: system, users, usernames, username, isNixOS, features, unfree, unfreeUnstable
│   ├── host-lib.nix      # Wrapper helpers: hmModule(), nixosModule(), sharedModule()
│   ├── features.nix      # Feature resolver + resolveUserModules helper
│   ├── pkgs.nix          # mkPkgs / mkPkgsUnstable: creates pkgs with allowUnfreePredicate per host
│   ├── nix-settings.nix  # Nix config: experimental features, prompt, substituters, trusted keys
│   └── builders/
│       ├── nixos.nix     # Builds nixosConfigurations for isNixOS=true hosts
│       └── home-manager.nix  # Builds homeConfigurations for isNixOS=false hosts
├── nixos/
│   └── default.nix       # Base NixOS: user groups, stateVersion, fish shell
├── home-manager/
│   └── default.nix       # HM defaults: stateVersion, nh, manual settings
└── features/
    ├── hm-base/          # CLI utilities: bat, eza, fd, fzf, helix, tmux, yazi, zoxide, …
    │   └── home.nix
    ├── hm-dev/           # Dev tools: alejandra, ansible, mise, nil, nixfmt, uv, …
    │   └── home.nix
    ├── hm-gpg/           # GPG agent with SSH support (7-day cache)
    │   └── home.nix
    └── hm-media/         # Media: yt-dlp (unfree)
        └── home.nix
```

### How Host Discovery Works

1. `discovery.nix` scans `hosts/` for `.nix` files and directories with `default.nix`
2. Each host is imported, its `modules` block extracted, and the remainder validated against `host-schema.nix`
3. The `modules` block is stitched back onto the validated config
4. `usernames` is derived from the `users` attrset (multi-user) or falls back to `username` (flat files)
5. The `isNixOS` flag determines host type: `true` → NixOS system config, `false` → Home Manager only

### Configuration Composition

**NixOS host** (`isNixOS = true`):

```
nix-settings → flake.nixos → feature nixos modules → host nixos modules → home-manager → feature home modules → host home modules → per-user modules
```

**Home Manager–only host** (`isNixOS = false`):

```
nix-settings → flake.home-manager → feature home modules → host home modules → per-user modules
```

### Feature System

Features are directories under `modules/features/<name>/` containing platform-specific `.nix` files (e.g., `home.nix`, `nixos.nix`). Hosts declare which features they want via the `features` list, and the resolver:

1. Validates that each feature name exists
2. Extracts `unfree` / `unfreeUnstable` lists from each feature module in isolation (without evaluating `pkgs`)
3. Returns the module paths and accumulated unfree lists

A host just lists features, and each feature contributes its own modules and unfree packages automatically.

## Adding a New Host

Create a new `.nix` file in `hosts/`:

```nix
# hosts/myhost.nix
_: {
  system = "x86_64-linux";
  username = "josh";
  isNixOS = false;

  features = [ "hm-base" "hm-dev" ];

  unfree = [];                    # Unfree packages from stable nixpkgs
  unfreeUnstable = [];            # Unfree packages from nixpkgs-unstable

  modules = {
    nixos  = [ (nixosModule ./myhost-system.nix) ];
    home   = [ (hmModule ./myhost-home.nix) ];
    shared = [ (sharedModule ./myhost-shared.nix) ];
  };
}
```

### Multi-User Hosts

Hosts can declare multiple users via a `users` attrset in `default.nix`, with per-user Home Manager configs in `home-<user>.nix` files.

```
hosts/family-desktop/
├── default.nix              # Barrel loader: system, users attrset, features, module imports
├── nixos.nix                # NixOS system config + user account definitions
├── shared.nix               # Shared between NixOS and HM contexts
├── home-mainuser.nix        # Home Manager module for mainuser (plain HM module)
└── home-anotheruser.nix     # Home Manager module for anotheruser
```

**`default.nix`** — barrel loader:

```nix
{ self, inputs, lib, ... }: {
  system   = "x86_64-linux";
  isNixOS  = true;
  features = [ "hm-base" "hm-gpg" "hm-media" ];

  users = {
    mainuser    = { enabled = true; };
    anotheruser = { enabled = false; };
  };

  modules = {
    nixos  = [ ./nixos.nix ];
    shared = [ ./shared.nix ];
  };
}
```

**`nixos.nix`** — NixOS system config and user account definitions:

```nix
{ lib, pkgs, usernames, ... }: {
  networking.hostName = "family-desktop";

  users.users = lib.genAttrs usernames (user: {
    isNormalUser = true;
    extraGroups  = [ "wheel" "networkmanager" ];
    home         = "/home/${user}";
    shell        = pkgs.bash;
  });

  users.users.mainuser.shell = pkgs.fish;
}
```

**`home-<user>.nix`** — plain Home Manager module, no wrapper:

```nix
{ pkgs, pkgsUnstable, ... }: {
  home.packages = with pkgsUnstable; [ khal yt-dlp lazygit ];
  programs.fish.enable = true;
}
```

The `enabled` flag lives in `default.nix`'s `users` attrset, so `home-<user>.nix` files are ordinary HM modules. The `usernames` option is **derived** from `users` (falls back to `[ username ]` for flat host files), so builders always call `host.usernames` uniformly.

#### Unfree Packages in Per-User Modules

Per-user `home-<user>.nix` modules can declare `unfree` / `unfreeUnstable` lists just like feature modules — they participate in the dry unfree-extraction pass automatically.

### Platform Module Helpers (`host-lib.nix`)

Three wrapper functions tag modules with their target platform:

| Helper         | Target       | Description                            |
| -------------- | ------------ | -------------------------------------- |
| `nixosModule`  | NixOS        | Imported only in `nixosConfigurations` |
| `hmModule`     | Home Manager | Imported in `homeConfigurations`       |
| `sharedModule` | Both         | Imported in both NixOS and HM contexts |

### Unfree Packages

This flake defaults to **non-unfree** — any non-free package causes a build failure unless whitelisted. Whitelists are declared once per host and propagate to both system and home configs.

```nix
# hosts/myhost.nix
_: {
  system = "x86_64-linux";
  unfree = [ "vscodium" ];              # from stable nixpkgs
  unfreeUnstable = [ "some-unfree-pkg" ];  # from nixpkgs-unstable
}
```

Find the exact package name: `nix eval --raw nixpkgs#<pkg>.pname`

### Using Unfree Packages

No additional declaration is needed in host modules — the predicate carries through automatically. Reference unfree packages via `pkgs` (stable) or `pkgsUnstable` (special args):

```nix
# myhost-home.nix
{ pkgs, pkgsUnstable, ... }:
{
  home.packages = [
    pkgs.vscodium        # unfree stable — allowed by unfree = [ "vscodium" ]
    pkgsUnstable.someUnfreePkg  # unfree unstable — allowed by unfreeUnstable
  ];
}
```

- `pkgs` uses stable nixpkgs with the `unfree` predicate.
- `pkgsUnstable` uses nixpkgs-unstable with the `unfreeUnstable` predicate.
- Missing from the whitelist → build fails with a license error listing the required package name.
- The same whitelist serves every module under that host — no per-module duplication.

**Never set `nixpkgs.config.allowUnfree = true`.** nixpkgs has a known bug where `allowUnfree` silently overrides `allowUnfreePredicate`, breaking per-host isolation. This flake uses only the predicate approach.

**CUDA / compute packages** (e.g. `cudatoolkit`) are also unfree and must be whitelisted.

## Flake Outputs

| Output                               | Description                                   | Example                                  |
| ------------------------------------ | --------------------------------------------- | ---------------------------------------- |
| `homeConfigurations."<user>@<host>"` | Per user-host Home Manager config             | `homeConfigurations.josh@methyl-bazzite` |
| `nixosConfigurations.<host>`         | NixOS system config (`isNixOS = true` only)   | `nixosConfigurations.family-desktop`     |
| `flake.features`                     | Discovered feature modules (for other flakes) | `flake.features.hm-base.home`            |
| `flake.flakeModules.nixos`           | NixOS base module (from `modules/nixos/`)     | `self.flakeModules.nixos`                |
| `flake.flakeModules.home-manager`    | HM base module (from `modules/home-manager/`) | `self.flakeModules.home-manager`         |

For multi-user hosts, the builder generates one `homeConfigurations.<user>@<host>` output per enabled user. Disabled users (via `users.<name>.enabled = false`) are excluded.

## Core Settings (Applied to All Configs)

- **Unfree packages:** per-host whitelist via `unfree` / `unfreeUnstable`
- **Substituters:** cache.nixos.org, wombatfromhell.cachix.org, nix-community.cachix.org
- **Prompt:** `(nix:$name)` when inside a derivation
- **Experimental features:** `nix-command`, `flakes`
