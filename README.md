# flakeroot — Unified Nix (Linux/Darwin) & Home Manager Configuration

A **flake-driven**, host-discovering config system for NixOS, macOS (darwin), and Home Manager — all from one repository.

## Quick Start

### Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled (`nix-command` + `flakes`)
- `$USER` and `$HOST` (or `/etc/hostname` on Linux) set in the environment

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
│   ├── discovery.nix        # Scans modules/hosts/<name>/ → {system, hasSystem, standaloneHome, users, userDefaults, homeFiles, unfreeStable, unfreeUnstable}
│   └── builders/
│       ├── default.nix      # pkgsFor/pkgsUnstableFor, mkAllowUnfree predicate
│       ├── system.nix       # mkSystem (NixOS/darwin), automaticHomeManagerModule for darwin
│       ├── home.nix         # mkHome (HM), distinct hm input per platform
│       ├── home-darwin.nix  # Implicit HM module for Darwin: useGlobalPkgs, per-user imports
│       └── configs.nix      # buildConfigs (foldlAttrs → nixos | darwin | home)
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
2. Each directory's `default.nix` is imported to read metadata:
   - `system` (defaults to `x86_64-linux`)
   - `standaloneHome` (defaults to `false`; when `true`, Darwin hosts skip system config)
   - `unfreeStable` / `unfreeUnstable` (whitelisted unfree packages per pkgs input)
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
# modules/hosts/myhost/default.nix
{
  system = "x86_64-linux";  # or "aarch64-darwin", etc.
  unfreeStable = [];
  unfreeUnstable = [];
}

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

### Home Manager–Only Darwin Host

Set `standaloneHome = true` in `default.nix` to skip the system configuration and produce only `homeConfigurations`:

```nix
# modules/hosts/myhost/default.nix
{
  system = "aarch64-darwin";
  standaloneHome = true;
}
```

### Unfree Packages

This flake defaults to **non-unfree** — any package with a non-free license will cause a build failure unless explicitly whitelisted. Whitelists are declared once per host in `default.nix` and propagate automatically to both system configs (`system.nix`) and all home configs (`home-<user>.nix`) for that host.

#### Declaring unfree packages

Each pkgs input has its own whitelist — a package must be listed under the correct key:

```nix
# modules/hosts/myhost/default.nix
{
  system = "x86_64-linux";
  unfreeStable = [ "vscodium" ];       # from nixpkgs (stable)
  unfreeUnstable = [ "some-unfree-pkg" ];  # from nixpkgs-unstable
}
```

To find the exact package name: `nix eval --raw nixpkgs#<pkg>.pname`

#### Using unfree packages in home configs

No additional declaration is needed in `home-<user>.nix` — the predicate from `default.nix` carries through. Simply reference unfree packages via `pkgs` (stable) or `pkgsStable` / `pkgsUnstable` (special args):

```nix
# modules/hosts/myhost/home-josh.nix
{ pkgs, pkgsStable, pkgsUnstable, ... }:
{
  home.packages = with pkgs; [
    # These work because "vscodium" is in unfreeStable:
    pkgsStable.vscodium   # or just pkgs.vscodium (same set)

    # These work because "some-unfree-pkg" is in unfreeUnstable:
    pkgsUnstable.someUnfreePkg
  ];
}
```

**Key points:**

- `pkgs` and `pkgsStable` are identical — both use the stable nixpkgs with the `unfreeStable` predicate.
- `pkgsUnstable` uses nixpkgs-unstable with the `unfreeUnstable` predicate.
- If a package is missing from the correct whitelist, the build will fail with a license error listing the required package name.
- The same whitelist serves every `home-<user>.nix` under that host — no per-user duplication.

#### Hardware requiring unfree packages (e.g. NVIDIA GPUs)

Hardware drivers like NVIDIA's proprietary GPU stack are unfree and must be whitelisted using the same mechanism as any other package. The key difference is that these packages are typically referenced via NixOS/Darwin module options rather than directly in `home.packages`, but the predicate still gates them.

**Example: NVIDIA GPU on a NixOS host**

```nix
# modules/hosts/myhost/default.nix — declare the hardware unfree packages
{
  system = "x86_64-linux";

  # nvidia-x11 = proprietary X.org driver + kernel module
  # nvidia-settings = GUI configuration utility
  # (nvidia-open is also unfree — only the kernel module is open-source)
  unfreeStable = [ "nvidia-x11" "nvidia-settings" ];
  unfreeUnstable = [];
}
```

```nix
# modules/hosts/myhost/system.nix — use the driver normally
{ pkgs, ... }:
{
  imports = [ ../../nixos ];

  hardware.nvidia = {
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    open = false;                        # set true for nvidia-open (still unfree userspace)
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  environment.systemPackages = with pkgs; [
    # Allowed because "nvidia-settings" is in unfreeStable:
    pkgs.nvidia-settings
  ];
}
```

```nix
# modules/hosts/myhost/home-josh.nix — same whitelist applies automatically
{ pkgs, pkgsStable, ... }:
{
  home.packages = with pkgs; [
    # Both resolve to the same whitelisted set:
    pkgsStable.nvidia-settings   # explicit stable reference
    pkgs.nvidia-settings          # implicit (identical)
  ];
}
```

**How it works under the hood:**

1. `discovery.nix` reads `unfreeStable = [ "nvidia-x11" … ]` from the host's `default.nix`.
2. `pkgsFor(system, unfreeStable)` imports nixpkgs with `config.allowUnfreePredicate = mkAllowUnfree [ "nvidia-x11" … ]`.
3. The NixOS `hardware.nvidia` module resolves `config.boot.kernelPackages.nvidiaPackages.stable` → `nvidia-x11` → the predicate allows it through.
4. Every `home-<user>.nix` for that host receives the same `pkgs` set — no per-user declaration needed.

**Important caveats:**

- **`nvidia-open` is unfree too.** Only the kernel module is open-source; the userspace libraries remain proprietary. If you use `open = true`, add `"nvidia-open"` to the whitelist instead of (or alongside) `"nvidia-x11"`.
- **Never set `nixpkgs.config.allowUnfree = true`.** nixpkgs has a known bug where `allowUnfree` silently overrides `allowUnfreePredicate`, breaking the per-host isolation. This flake uses only the predicate approach — keep it that way.
- **CUDA / compute packages** (e.g. `cudatoolkit`) are also unfree and must be whitelisted under the correct key (`unfreeStable` or `unfreeUnstable`).

## Supported Platforms

| Platform         | NixOS | Darwin | Home Manager |
| ---------------- | ----- | ------ | ------------ |
| `x86_64-linux`   | ✅    | —      | ✅           |
| `aarch64-linux`  | ✅    | —      | ✅           |
| `x86_64-darwin`  | —     | ✅     | ✅           |
| `aarch64-darwin` | —     | ✅     | ✅           |

> **macOS (Darwin) / Home Manager:** On Darwin systems, use `nh darwin switch` for full system + Home Manager configuration, or `nh home switch` for Home Manager only. Home Manager works independently on both Linux and Darwin regardless of the host's `system` attribute.

## Core Settings (Applied to All Configs)

- **Unfree packages:** per-host whitelist via `unfreeStable` / `unfreeUnstable` in each host's `default.nix`
- **Substituters:** cache.nixos.org, wombatfromhell.cachix.org, nix-community.cachix.org
- **Prompt:** `(nix:$name)` when inside a derivation
- **Experimental features:** `nix-command`, `flakes`

## See Also

- [DESIGN.md](./DESIGN.md) — Full architecture, dependency graph, and build pipeline diagrams
