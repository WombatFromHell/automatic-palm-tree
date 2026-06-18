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

## User Options

| Option      | Default | Description                                                           |
| ----------- | ------- | --------------------------------------------------------------------- |
| `enabled`   | `true`  | Include the user in `osUsernames`                                     |
| `isAdmin`   | `false` | Add `wheel` to `extraGroups`                                          |
| `hmEnabled` | `true`  | Set `false` to create the NixOS user but skip its home-manager module |

Feature modules under `features/<name>/` are auto-discovered — no registration needed.
