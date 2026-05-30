# flakeroot

A flake-driven, host-discovering config system for NixOS and Home Manager.

## Setup

Clone the flake into `~/.config/flakeroot` and set `NH_FLAKE` so `nh` and other tools find it automatically:

```bash
git clone <repo-url> ~/.config/flakeroot
```

Add to your shellrc:

```bash
export NH_FLAKE="$HOME/.config/flakeroot"
```

This lets `nh os switch` and `nh home switch` resolve the flake without `--flake` flags.

## Switching Configurations

```bash
# List all discovered configs
nix flake show

# NixOS system + Home Manager
nh os switch

# Home Manager only (auto-detects user@host)
nh home switch
```

Or with home-manager: `home-manager switch --flake . --impure`
Or with nixos-rebuild: `nixos-rebuild switch --flake .#<hostname>`

## Adding a Host

### Single-File Host

Create `hosts/<name>.nix`:

```nix
_: {
  system = "x86_64-linux";
  username = "josh";
  isNixOS = false;

  features = [ "hm-base" "hm-dev" ];
  unfree = [];
  unfreeUnstable = [];

  modules = {
    home = [ (hmModule ./my-config.nix) ];
  };
}
```

### Multi-File Host

Create a directory `hosts/<name>/` with a `default.nix` barrel loader and optional feature files:

```
hosts/family-desktop/
├── default.nix          # System, users, features, module paths
├── nixos.nix            # NixOS system config (imported via modules.nixos)
├── shared.nix           # Shared between NixOS + HM (imported via modules.shared)
├── home-mainuser.nix    # Per-user HM module for mainuser
└── home-anotheruser.nix # Per-user HM module for anotheruser
```

**`default.nix`** — barrel loader:

```nix
{ self, inputs, lib, ... }: {
  system   = "x86_64-linux";
  isNixOS  = true;

  users = {
    mainuser    = { enabled = true; };
    anotheruser = { enabled = false; };
  };

  features = [ "hm-base" "hm-gpg" ];

  modules = {
    nixos  = [ ./nixos.nix ];
    shared = [ ./shared.nix ];
  };
}
```

**`nixos.nix`** — NixOS system config:

```nix
{ lib, pkgs, usernames, ... }: {
  networking.hostName = "family-desktop";

  users.users = lib.genAttrs usernames (user: {
    isNormalUser = true;
    extraGroups  = [ "wheel" "networkmanager" ];
    home         = "/home/${user}";
  });
}
```

**`home-<user>.nix`** — plain Home Manager module (no wrapper):

```nix
{ pkgs, pkgsUnstable, ... }: {
  home.packages = with pkgs; [ helix tmux ];
  programs.fish.enable = true;
}
```

## Module Helpers

Three wrapper functions tag modules with their target platform:

| Helper         | Target       | Imported in                |
| -------------- | ------------ | -------------------------- |
| `nixosModule`  | NixOS        | `nixosConfigurations` only |
| `hmModule`     | Home Manager | `homeConfigurations` only  |
| `sharedModule` | Both         | Both NixOS and HM contexts |

Usage: `(nixosModule ./my-file.nix)` — the wrapper adds a `platform` attribute that the builders use to route modules to the correct configuration.

## Features

Features live under `modules/features/<name>/` and contain platform-specific `.nix` files (e.g., `home.nix`, `nixos.nix`). Hosts declare which features they want:

```nix
features = [ "hm-base" "hm-dev" ];
```

The resolver auto-discovers features, validates names, and extracts unfree whitelists before merging modules. No registration needed — just create the directory.

## Unfree Packages

Unfree packages are **rejected by default** unless whitelisted per-host:

```nix
unfree = [ "vscodium" ];              # from stable nixpkgs
unfreeUnstable = [ "yt-dlp" ];        # from nixpkgs-unstable
```

Reference them normally in modules — the predicate carries through automatically:

```nix
{ pkgs, pkgsUnstable, ... }: {
  home.packages = [ pkgs.vscodium pkgsUnstable.yt-dlp ];
}
```

Missing from the whitelist → build fails with the package name. Find it via `nix eval --raw nixpkgs#<pkg>.pname`.

**Never set `nixpkgs.config.allowUnfree = true`** — it silently overrides the predicate and breaks per-host isolation.
