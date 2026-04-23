Unified NixOS/Darwin/Home Manager config using **flake-parts** with automatic host discovery.

## Quick Start

```bash
# Home Manager (auto-detects $HOSTNAME + $USER)
home-manager switch --flake . --impure

# Explicit user@host
home-manager switch --flake .#josh@methyl-bazzite

# NixOS / Darwin
nixos-rebuild switch --flake .#<hostname>
darwin-rebuild switch --flake .#<hostname>
```

## Structure

```
modules/
├── core/          # Discovery, builders, shared nix settings (substituters, prompt)
├── nixos/         # Base NixOS module (unfree, user groups, stateVersion)
├── darwin/        # Base Darwin module (shell, direnv, TouchID sudo)
├── home-manager/  # Base HM modules (base + dev tools; gpg.nix optional)
└── hosts/<name>/  # Auto-discovered per-host configs
    ├── home-<user>.nix   # Per-user HM config (required for users)
    └── system.nix        # System options: { platform, module } (optional)
```

See [DESIGN.md](./DESIGN.md) for the full architecture and dependency graph.

## Adding a Host

Create `modules/hosts/<name>/` with at least one `home-<user>.nix`:

```nix
# home-josh.nix
{pkgs, ...}: {
  imports = [ ../../home-manager ];  # base + dev tools
  # imports = [ ../../home-manager/gpg.nix ];  # optional GPG agent
}
```

For NixOS/Darwin, add `system.nix`:

```nix
# system.nix
{
  platform = "x86_64-darwin";  # or x86_64-linux (default)
  module = {pkgs, ...}: {
    imports = [ ../../darwin ];  # or ../../nixos
    environment.systemPackages = with pkgs; [ git neovim ];
  };
}
```

The `platform` attr determines host type: `*-darwin` → Darwin, else NixOS.
Hosts without `system.nix` are Home Manager–only (defaulting to Linux).

## Supported Platforms

| Platform         | NixOS | Darwin | Home Manager |
| ---------------- | ----- | ------ | ------------ |
| `x86_64-linux`   | ✅    | —      | ✅           |
| `aarch64-darwin` | —     | ✅     | ✅           |
| `aarch64-linux`  | ✅    | —      | ✅           |

## Flake Outputs

| Output                               | Description                              |
| ------------------------------------ | ---------------------------------------- |
| `homeConfigurations."<user>@<host>"` | Per user-host pair                       |
| `homeConfigurations.default`         | Auto-inferred from `$HOSTNAME` + `$USER` |
| `nixosConfigurations.<host>`         | If `system.nix` exists on Linux          |
| `darwinConfigurations.<host>`        | If `system.nix` exists on Darwin         |
| `devShells.<system>.default`         | Dev shell (`nixpkgs-fmt`, `alejandra`)   |

## Importing from Other Flakes

```nix
inputs.myhost = { url = "github:you/flakeroot"; };
{
  homeConfigurations.myuser = inputs.home-manager.lib.homeManagerConfiguration {
    modules = [ inputs.myhost.modules.home-manager.default ];
  };
}
```
