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

Create `hosts/<name>.nix`:

```nix
_: let
  myHome = { pkgs, pkgsUnstable, ... }: {
    home.packages = with pkgsUnstable; [ helix tmux ];
  };
in {
  bootstrap = true; # set to false after first build for caching
  system = "x86_64-linux";
  isNixOS = false;

  features = [ "hm-base" "hm-dev" ];

  homeModules.someuser = [myHome];
}
```

## Multi-File Host (NixOS)

Create `hosts/<name>/default.nix`:

```nix
_: {
  bootstrap = true; # set to false after first build for caching
  system   = "x86_64-linux";
  isNixOS  = true;

  users.someuser  = { isAdmin = true; hmEnabled = false; };

  features = [ "hm-base" "hm-gpg" "nixos-podman" ];

  nixosModules = [ ./nixos.nix ];
}
```

`hosts/<name>/nixos.nix` — `users.users` are auto-generated for all `osUsernames`; add per-user groups here:

```nix
{ pkgs, hostConfig, ... }: {
  networking.hostName = "my-machine";

  users.users.someuser.extraGroups = [ "podman" ];
}
```

`hosts/<name>/home-someuser.nix` — plain Home Manager module, auto-discovered:

```nix
{ pkgs, pkgsUnstable, ... }: {
  home.packages = with pkgs; [ helix tmux ];
  programs.fish.enable = true;
}
```

## User Options

| Option      | Type   | Default | Description                                                           |
| ----------- | ------ | ------- | --------------------------------------------------------------------- |
| `enabled`   | `bool` | `true`  | Include the user in `osUsernames`                                     |
| `isAdmin`   | `bool` | `false` | Add `wheel` to `extraGroups`                                          |
| `hmEnabled` | `bool` | `true`  | Set `false` to create the NixOS user but skip its home-manager module |

Feature modules under `features/<name>/` are auto-discovered — no registration needed.
