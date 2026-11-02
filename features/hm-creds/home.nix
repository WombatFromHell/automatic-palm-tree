# 'hm-creds': credsctl, the helper over the record store in ~/.local/share/credentials.
# One file per secret; the extension picks the backend — .cred is decrypted by systemd-creds
# (silent, machine-bound), .age by age with a passphrase-protected identity (portable, but only
# unlockable from a terminal). Records are immutable: encrypt never overwrites and writes 0400,
# so a change is remove + re-add. Machine-local secrets consumed by automation stay .cred.
#
# Opt-in through the host feature list (hosts/<host>/default.nix → "hm-creds"), like every other
# feature — the feature list is the gate, no enable flag. `credsctl` with no arguments prints the
# whole contract: commands, the change recipe, the backend rule, and the exit codes.
#
# systemd-creds comes from the host PATH (/usr/bin/systemd-creds on Bazzite, systemd's copy on
# NixOS). sops and age are added here: sops is what sopsctl drives, and age only for age-keygen in
# `sopsctl init` (agenix carries its own age and does not put it on PATH).
{ pkgs, ... }:
{
  home.packages = [
    pkgs.age
    pkgs.sops
    (pkgs.writeShellApplication {
      name = "credsctl";
      text = builtins.readFile ./credsctl.sh;
    })
    (pkgs.writeShellApplication {
      name = "sopsctl";
      text = builtins.readFile ./sopsctl.sh;
    })
  ];
}
