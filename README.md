# Nix Flake Configuration

A unified Nix (Linux/Darwin) and Home Manager configuration using the
dendritic pattern with automatic host and user discovery.

## Directory Structure

```
modules/
├── core/              # Shared NixOS/Darwin settings
├── darwin/            # Base Darwin module
├── home-manager/      # Base Home Manager modules
└── hosts/
    └── <hostname>/
        ├── home-<user>.nix   # Per-user Home Manager config (required)
        └── system.nix        # System-level config (optional)
```

### File Roles

| File              | Purpose                             | Required              |
| ----------------- | ----------------------------------- | --------------------- |
| `home-<user>.nix` | Per-user Home Manager config        | At least one per host |
| `system.nix`      | System-level options (Darwin/NixOS) | Optional              |

### Auto-Inferred Metadata

| Metadata   | Source                                                         |
| ---------- | -------------------------------------------------------------- |
| `hostname` | Parent directory name                                          |
| `username` | Filename pattern `home-<user>.nix`                             |
| `system`   | `system.nix` top-level `system` attr, default `"x86_64-linux"` |
| `home.uid` | Set in `home-<user>.nix` via `home.uid` option                 |

## Adding a New Host

### Single-user Linux (Home Manager only)

```
modules/hosts/my-laptop/
└── home-someuser.nix
```

```nix
# home-someuser.nix
{pkgs, ...}: {
  imports = [ ../../home-manager ];

  home.username = "someuser";
  home.uid = 1000;

  # Per-user overrides here
}
```

No `system.nix` needed — defaults to `x86_64-linux`, type = `"home"`.

### Multi-user Host

```
modules/hosts/shared-box/
├── home-someuser.nix
├── home-alex.nix
└── system.nix          # optional, shared system config
```

Both users get separate `homeConfigurations` entries:

- `someuser@shared-box`
- `alex@shared-box`

### Darwin Host

```
modules/hosts/my-mac/
├── home-someuser.nix
└── system.nix
```

```nix
# system.nix
{
  system = "x86_64-darwin";  # or "aarch64-darwin"

  module = {pkgs, ...}: {
    imports = [ ../../darwin ];

    environment.systemPackages = with pkgs; [ git neovim ];
    programs.zsh.enable = true;
  };
}
```

The `system` attr triggers `"darwin"` hostType detection. The `module` function
is evaluated laziously within the Nix module system (so `pkgs` is available).

### NixOS Host (full system management)

```
modules/hosts/my-server/
├── home-someuser.nix
└── system.nix
```

```nix
# system.nix
{
  system = "x86_64-linux";  # optional — this is the default

  module = {pkgs, ...}: {
    imports = [ ../../nixos ];

    # system-level NixOS options
    services.openssh.enable = true;
  };
}
```

## Usage

### Home Manager (standalone)

```bash
# Auto-detect current host + user
home-manager switch --flake ~/.nix --impure

# Explicit user@host
home-manager switch --flake ~/.nix#someuser@methyl-bazzite

# Dry run
home-manager build --flake ~/.nix#someuser@methyl-bazzite --dry-run
```

### NixOS

```bash
nixos-rebuild switch --flake ~/.nix#<hostname>
```

### Darwin

```bash
darwin-rebuild switch --flake ~/.nix#<hostname>
```

### Flake Compositions

Other flakes can import your modules:

```nix
{
  inputs.myhost.url = "github:you/nix";
  outputs = inputs: {
    homeConfigurations.myuser =
      inputs.home-manager.lib.homeManagerConfiguration {
        modules = inputs.myhost.lib.mkHostHomeModule "myhost" "myuser";
      };
  };
}
```

## Flake Outputs

| Output                               | Description                                          |
| ------------------------------------ | ---------------------------------------------------- |
| `homeConfigurations."<user>@<host>"` | Home Manager config per user-host pair               |
| `nixosConfigurations.<host>`         | NixOS system config (if system.nix exists + linux)   |
| `darwinConfigurations.<host>`        | Darwin system config (if system.nix exists + darwin) |
| `homeManagerModules.default`         | Shared Home Manager base modules                     |
| `nixosModules.default`               | Shared NixOS core modules                            |
| `darwinModules.default`              | Shared Darwin core modules                           |
| `lib.*`                              | Helper functions for composing configurations        |
