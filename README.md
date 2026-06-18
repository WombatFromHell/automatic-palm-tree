# flakeroot

Flake-driven, host-discovering config system for NixOS and Home Manager.

## Deploy

```bash
export NH_FLAKE="$HOME/.config/flakeroot"
nh os switch          # NixOS system + Home Manager
nh home switch        # Home Manager only
nix flake show        # List all discovered configs
```

## Single-File Host (HM-only)

`hosts/<name>.nix`:

```nix
_: {
  bootstrap = true; # set to false after first build for caching
  system = "x86_64-linux";
  isNixOS = false;
  features = [ "hm-base" ];
  homeModules.someuser = [{
    home.packages = with pkgsUnstable; [ helix tmux ];
  }];
}
```

## Multi-File Host (NixOS)

`hosts/<name>/default.nix`:

```nix
_: {
  bootstrap = true;
  system   = "x86_64-linux";
  isNixOS  = true;
  users.someuser.isAdmin = true;
  features = [ "hm-base" "hm-dev" "nixos-base" "nixos-podman" ];
  nixosModules = [ ./nixos.nix ];
}
```

Sibling files are auto-discovered from the `hosts/<name>/` directory:

`nixos.nix` — standard NixOS module:

```nix
_: {
  imports = [./hardware-configuration.nix];
  boot.loader.systemd-boot.enable = true;
  networking.hostName = "my-machine";
  services.openssh.enable = true;
  users.users.someuser.extraGroups = ["podman"];
}
```

`home-<user>.nix` — plain Home Manager module (`pkgs`, `pkgsUnstable`, `hostConfig` available):

```nix
{ pkgsUnstable, ... }: {
  home.packages = with pkgsUnstable; [ heroic khal trash-cli ];
  programs.gpg.enable = true;
}
```

## Host Inheritance

A host can inherit from another host's config, overriding only what differs. This avoids
repeating the same feature list, user declarations, and module config across variants
(e.g., a bare-metal host and its QEMU VM sibling).

### Host metadata (`default.nix`)

Use Nix's `import + //` to copy the base attrset and override specific fields:

```nix
# hosts/myhost-vm/default.nix
_: let
  base = import ../myhost/default.nix {};
in base // {
  isQemuVM = true;
}
```

### NixOS module (`nixos.nix`)

Split shared config into a `base.nix` (no hardware import) and have each variant's
`nixos.nix` import its own hardware config plus the base:

```
hosts/myhost/                    # bare metal
├── default.nix                  # isQemuVM = false
├── base.nix                     # shared boot, services, feature toggles
├── nixos.nix                    # imports [./hardware-configuration.nix ./base.nix]
├── hardware-configuration.nix
└── home-josh.nix

hosts/myhost-vm/                 # QEMU variant
├── default.nix                  # isQemuVM = true, inherits features/users from myhost
├── nixos.nix                    # imports [../myhost/base.nix ./hardware-configuration.nix]
├── hardware-configuration.nix   # qemu-guest profile
└── home-josh.nix                # imports [../myhost/home-josh.nix]
```

This keeps `hardware-configuration.nix` strictly per-host and avoids conflicting
definitions when both variants inherit the same `nixos.nix`.

## User Options

| Option      | Default | Description                                                           |
| ----------- | ------- | --------------------------------------------------------------------- |
| `enabled`   | `true`  | Include the user in `osUsernames`                                     |
| `isAdmin`   | `false` | Add `wheel` to `extraGroups`                                          |
| `hmEnabled` | `true`  | Set `false` to create the NixOS user but skip its home-manager module |
| `isQemuVM`  | `false` | Whether this host is a QEMU/KVM virtual machine                       |

Feature modules under `features/<name>/` are auto-discovered — no registration needed.
