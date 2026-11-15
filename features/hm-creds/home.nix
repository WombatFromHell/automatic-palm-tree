# 'hm-creds': credsctl over the record store in ~/.local/share/credentials. The suffix picks the
# backend — .cred is decrypted by systemd-creds (silent, machine-bound, one secret per record), a
# *.sops.* record by sops itself (portable, key read from a file, so no terminal, and one record may
# hold several fields whose names are environment variables) — and records are immutable: encrypt
# never overwrites and writes 0400, so a change is remove + re-add. Machine-local secrets consumed by
# automation stay .cred; a *.sops.* record is a map.
#
# Opt-in through the host feature list (hosts/<host>/default.nix → "hm-creds"), like every other
# feature — the feature list is the gate, no enable flag. `credsctl help` prints the commands, the
# change recipe, the backend rule and the exit codes.
#
# systemd-creds comes from the host PATH (/usr/bin/systemd-creds on Bazzite, systemd's copy on
# NixOS). Everything else is a `runtimeInputs` entry, because writeShellApplication exports PATH
# from that list: credsctl runs jq, sops, age (age-keygen, for `init`) and ssh-to-age (for
# `init --from-ssh`). The passphrase of a protected ssh origin travels to ssh-to-age in that
# command's own environment: ssh-to-age is not ssh and never reads SSH_ASKPASS, so no askpass helper
# is shipped — a helper here could only be called by hand. `sops` is also installed plainly so a
# person can run `sops edit` on a record.
{pkgs, ...}: {
  home.packages = [
    pkgs.sops
    pkgs.age
    pkgs.ssh-to-age
    (pkgs.writeShellApplication {
      name = "credsctl";
      text = builtins.readFile ./credsctl.sh;
      runtimeInputs = [pkgs.jq pkgs.sops pkgs.age pkgs.ssh-to-age];
    })
  ];
}
