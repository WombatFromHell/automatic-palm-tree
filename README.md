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
_: {
  system = "x86_64-linux";
  isNixOS = false;

  features = [ "hm-base" "hm-dev" ];

  modules.home = [ (hmModule ./my-config.nix) ];
}
```

## Multi-File Host (NixOS)

Create `hosts/<name>/default.nix`:

```nix
{ self, inputs, lib, ... }: {
  system   = "x86_64-linux";
  isNixOS  = true;

  users.josh  = { isAdmin = true; };
  users.guest = {};

  features = [ "hm-base" "hm-gpg" "nixos-podman" ];

  modules.nixos = [ ./nixos.nix ];
}
```

`hosts/<name>/nixos.nix` — `users.users` are auto-generated for all `osUsernames`; add per-user groups here:

```nix
{ pkgs, hostConfig, ... }: {
  networking.hostName = "my-machine";

  users.users.josh.extraGroups = [ "podman" ];
}
```

`hosts/<name>/home-josh.nix` — plain Home Manager module:

```nix
{ pkgs, pkgsUnstable, ... }: {
  home.packages = with pkgs; [ helix tmux ];
  programs.fish.enable = true;
}
```

## Module Helpers

| Helper         | Target       | Usage                            |
| -------------- | ------------ | -------------------------------- |
| `nixosModule`  | NixOS only   | `modules.nixos = [ (nixosModule ./f.nix) ];` |
| `hmModule`     | HM only      | `modules.home = [ (hmModule ./f.nix) ];`      |
| `sharedModule` | Both         | `modules.shared = [ (sharedModule ./f.nix) ];`|

Features discover modules under `modules/features/<name>/` automatically — no registration needed.
