# Nix deploy recipes, ported from ~/.config/fish/helpers/nix.fish, plus the
# cherry-picked recipes from the old /etc/Justfile (features/nixos-justnh, now
# removed). Its switch/rswitch/dswitch/dry are already covered here by os-switch,
# rebuild and os-build --dry-run, so only default/info/clean came over.
#
# Flags, accepted by every recipe and in any order: --dry-run = evaluate only, never
# build/copy/ssh; --sudo = run the nix client as root, with Nix's bin dir first in the PATH
# (sudo's env_reset would drop it). A bare argument is the target (user
# for home recipes, host for system recipes) and may appear anywhere; omit it to use the
# local host, which for system recipes may not be a NixOS host at all -- `njust info`
# lists them and the build says so. Anything else is forwarded verbatim to the client, so
# `--option name value` works everywhere. A token that starts with `-` is a flag, short or
# long, so `-L` and `-v` reach the client instead of becoming the target; only the flags
# listed in `_deploy` consume a value token (`nix build`'s `-o`/`-I`/`-f` and
# `nixos-rebuild`'s `-p`), so a boolean flag never eats the target. This
# nix rejects `--flag=value`, so a value cannot be attached. ponytail: option
# values must be one token (a multi-word value gets split and the client rejects
# it loudly — see the interpolation note above); `--with-xilo` is helper-level like
# nix.fish's `_nfb` strips it: it is
# acted on here (push the built closure to the xilo cache) and never forwarded.
#
# How far a recipe goes is its *mode*, a parameter of `_deploy`, not a flag: build builds;
# switch builds then activates; boot/test build and set or check the next boot entry;
# activate activates the generation that is already built and builds nothing; push uploads the
# generation this host already has *active*, resolved from its profile rather than an out-link, so
# it survives a reboot or a cleanup that dropped `/tmp` — nothing is built or activated, and
# re-running it is cheap: xilo asks the server which paths it already has and uploads only the
# rest.
# A recipe's *scope* is what it builds and where it activates: hm and os activate on this host,
# os-deploy and nas copy a closure to a remote host and activate it there. Recipe comments
# stay single-line because `just --list` prints only the last line of a comment block.
#
# shortcut: each client's flags are parsed by its own loop (`_exec`, `build`, `_clean`, `sweep`,
# `_deploy`) rather than one shared parser, because the clients differ (`nh` vs `nix build` vs
# `nix-env`) and `--dry-run` means "print it" in `_exec` but "evaluate for real" in `build`. A
# shared parser would hand argv back through stdout, which word-splits and globs it. Upgrade if a
# fourth client needs the same table.
#
# Reached through `njust`, a wrapper pinned to this file, so plain `just`
# still finds your project justfiles.

# Shebang recipes below run `set -uf` (no -e: a recipe's status is its last command's). just joins
# a variadic argument list when it interpolates it, so argument boundaries are lost on the way in:
# a value must be one token, and a stray `*` expands against the caller's cwd. `quote()` would make
# the whole list one token, which is worse. `set shell` cannot
# cover them -- just runs a shebang recipe through its own shebang, not this shell.
set shell := ["bash", "-uc"]

# Shared values: one source of truth for every recipe below. Paths use env_var
# rather than `~` because some recipes interpolate them inside quotes.
flake := env_var_or_default("FLAKE_ROOT", env_var("HOME") + "/.config/flakeroot")
# Options every recipe passes. All of these are accepted by upstream Nix; the
# Determinate-only knobs (eval-cache, eval-cores, or-as-identifier) are not here.
nix_opts := "--option show-trace true --option connect-timeout 5 --option extra-experimental-features 'nix-command flakes'"

# Closure attribute roots, out-links, and the system profile, spelled once.
hm_root := flake + "#homeConfigurations."
os_root := flake + "#nixosConfigurations."
hm_attr := ".activationPackage"
os_attr := ".config.system.build.toplevel"
# Out-links: the name of the symlink, under a directory only this user owns. /tmp is world-writable
# with the sticky bit, so a predictable name there is another user's symlink on a shared host;
# XDG_RUNTIME_DIR (/run/user/UID, 0700) is the private one, and /tmp is the fallback for a host
# without it.
out_dir := env_var_or_default("XDG_RUNTIME_DIR", "/tmp")
hm_link := "hm-result"
os_link := "nixos-result"
deploy_link := "nixos-deploy-result"
# The generation this host has *active*, spelled as one symlink per scope: `realpath` walks
# profile -> generation link -> store path, and both symlinks are world-readable, so reading the
# active closure needs no root. `home-manager switch` writes its generations under XDG_STATE_HOME
# (default ~/.local/state); the system profile is root-owned but readable. Both are overridable so
# a test, or a second profile, can point at its own path.
sys_profile := env_var_or_default("SYSTEM_PROFILE", "/nix/var/nix/profiles/system")
hm_profile := env_var_or_default("XDG_STATE_HOME", env_var("HOME") + "/.local/state") + "/nix/profiles/home-manager"

# The NAS lives in its own flake and pulls from its own Cachix cache; these two
# options are copied verbatim from nix.fish's nixos_deploy_nas.
nas_flake := env_var_or_default("NAS_ROOT", env_var("HOME") + "/Projects/nasty-config")
nas_cache := "--option extra-substituters https://nasty.cachix.org --option extra-trusted-public-keys nasty.cachix.org-1:s+X88yw6+asphCNphTId/RQZHfmDF4fQ0uyzEz5SxLc="

# xilo cache a built closure is pushed to. A push always requires a token, so credentials come
# from XILO_URL/XILO_TOKEN or a saved `xilo login` profile; `_push` resolves them in the order your
# fish helper did. The cache name only: url/key stay in modules/cache-registry.nix.
xilo_cache := env_var_or_default("XILO_CACHE", "default/xilopkgs")
# One elevation prefix: sudo's env_reset drops your PATH, so Nix's bin dir goes first and your
# PATH stays behind it. Your fish `sudoe`, minus -E (needs sudoers SETENV), the PATH dedup and
# the fish-function branch — none of those apply to a bash recipe.
elev := 'sudo env "PATH=$HOME/.nix-profile/bin:$PATH"'

# Local defaults, so recipe signatures stay short enough for `just --list` to align.
hn := `hostname`
me := `whoami` + "@" + hn

# `njust` with no recipe lists the recipes (old /etc/Justfile `default`).
default:
    @just --justfile "{{ justfile() }}" --list

# `nh os info` lists the generations of a *system profile* and takes no flake argument
# (nh 4.x rejects one), so the names come from the flake's own outputs; attrNames does not
# force a config, so this stays a cheap eval.

# Which configs this flake exposes (old /etc/Justfile `list`).
info:
    #!/usr/bin/env bash
    set -uf pipefail
    nix eval --impure {{ nix_opts }} --expr 'let f = builtins.getFlake "{{ flake }}"; in builtins.attrNames f.nixosConfigurations ++ builtins.attrNames f.homeConfigurations'

# --- cleanup -----------------------------------------------------------------
# Two families on one convention (`verb-scope`): the traditional nix commands, and nh's own
# bundle below. `_exec` is the only place that echoes, elevates or honours --dry-run here; `_gens`
# is the only place generation argv is built. --dry-run means "print it, run nothing" — nh's own
# `-n` (run nh, let it print its plan) is passed through verbatim.

# Echo the command, then run it: --sudo elevates, --dry-run prints and runs nothing.
_exec *cmd:
    #!/usr/bin/env bash
    set -uf pipefail
    arr=({{ cmd }})
    dry=false
    elevate=false
    keep=()
    for a in "${arr[@]}"; do
        case "$a" in
        --dry-run) dry=true ;;
        --sudo) elevate=true ;;
        *) keep+=("$a") ;;
        esac
    done
    [[ "$elevate" == true ]] && keep=({{ elev }} "${keep[@]}")
    if [[ "$dry" == true ]]; then
        echo "would run: ${keep[*]}"
        exit 0
    fi
    echo "${keep[*]}"
    "${keep[@]}"

# Generation verbs for a client's own default profile: `nix-env` for the user, `home-manager`
# for the home generations. Specs are nix-env's grammar (ids, `old`, `30d`, `+2M`, `1y`), and
# neither scope needs root. Scope decides the client and the verb.
_gens scope="user" action="list" *args:
    #!/usr/bin/env bash
    set -uf pipefail
    arr=({{ args }})
    specs=()
    for a in "${arr[@]}"; do [[ "$a" == -* ]] || specs+=("$a"); done
    # An empty spec would delete every generation of the default profile; a flag is not a spec.
    [[ "{{ action }}" == rm ]] && [[ ${#specs[@]} == 0 ]] && {
        echo "usage: njust rm-{{ scope }} <id|old|30d|+2M|1y>" >&2
        exit 1
    }
    case "{{ scope }}:{{ action }}" in
    user:list) verb=--list-generations ;;
    user:rm)   verb=--delete-generations ;;
    hm:list)   verb=generations ;;
    hm:rm)     verb=remove-generations ;;
    *) echo "Error: unknown generation scope/action '{{ scope }}:{{ action }}'" >&2; exit 1 ;;
    esac
    client=nix-env
    [[ "{{ scope }}" == hm ]] && client=home-manager
    just --justfile "{{ justfile() }}" _exec "$client" "$verb" "${arr[*]}"

# Generation verbs against an explicit profile (`nix-env --profile`). The system profile is
# root-owned, so this always elevates; `scope` says which profile you mean, which is what the
# usage line and the missing-profile guard say back to you.
_gens_profile action="list" profile=sys_profile scope="os" *args:
    #!/usr/bin/env bash
    set -uf pipefail
    arr=({{ args }})
    specs=()
    for a in "${arr[@]}"; do [[ "$a" == -* ]] || specs+=("$a"); done
    [[ "{{ action }}" == rm ]] && [[ ${#specs[@]} == 0 ]] && {
        echo "usage: njust rm-{{ scope }} <id|old|30d|+2M|1y>" >&2
        exit 1
    }
    [[ ! -e "{{ profile }}" ]] && {
        # A non-NixOS host has no system profile: that is not an error, it is nothing to list.
        [[ "{{ scope }}" == os ]] && { echo "{{ profile }}: no system profile on this host"; exit 0; }
        echo "Error: no profile at {{ profile }}" >&2
        exit 1
    }
    verb=--list-generations
    [[ "{{ action }}" == rm ]] && verb=--delete-generations
    # The system profile is root-owned; a profile you named yourself is not.
    root=""
    [[ "{{ scope }}" == os ]] && root=--sudo
    just --justfile "{{ justfile() }}" _exec nix-env --profile "{{ profile }}" "$verb" "${arr[*]}" $root

# Generations of the user's nix-env profile.
list-user *args: (_gens "user" "list" args)
rm-user *args: (_gens "user" "rm" args)
# The same profile through the new CLI (`nix profile`), which spells history differently.
history-user *args:
    @just --justfile "{{ justfile() }}" _exec nix profile history {{ nix_opts }} {{ args }}
wipe-user *args:
    @just --justfile "{{ justfile() }}" _exec nix profile wipe-history {{ nix_opts }} {{ args }}

# Home-manager generations (nix.fish: hmls / hmrm).
list-hm *args: (_gens "hm" "list" args)
rm-hm *args: (_gens "hm" "rm" args)

# home-manager takes `date -d` grammar ("-30 days"); nix-env's grammar is the one we expose, so
# the translation lives here once. Deleting *user* generations by duration is `rm-user 30d`.
expire-hm duration="30d" *args:
    #!/usr/bin/env bash
    set -uf pipefail
    [[ "{{ duration }}" =~ ^([0-9]+)([dwmy])$ ]] || { echo "Error: duration '{{ duration }}' is not nix-env grammar (30d, 12w, 1y)" >&2; exit 1; }
    case "${BASH_REMATCH[2]}" in
    d) unit=days ;; w) unit=weeks ;; m) unit=months ;; y) unit=years ;;
    esac
    just --justfile "{{ justfile() }}" _exec home-manager expire-generations "-${BASH_REMATCH[1]} ${unit}" {{ args }}

# NixOS generations (nix.fish: nhdls / nhdrm); the system profile is root-owned, so `os` always
# elevates. Pass a profile to list or clean another one.
list-os profile=sys_profile *args: (_gens_profile "list" profile "os" args)
rm-os *args: (_gens_profile "rm" sys_profile "os" args)
list-profile profile *args: (_gens_profile "list" profile "profile" args)
rm-profile profile *args: (_gens_profile "rm" profile "profile" args)

# Store GC. `nix store gc` is the new CLI and touches no generations; `nix-collect-garbage` is the
# pre-nix-command spelling that deletes generations too, with its own duration form.
gc *args:
    @just --justfile "{{ justfile() }}" _exec nix store gc {{ nix_opts }} {{ args }}
gc-old *args:
    @just --justfile "{{ justfile() }}" _exec nix-collect-garbage --delete-old {{ args }}
gc-older-than duration *args:
    @just --justfile "{{ justfile() }}" _exec nix-collect-garbage --delete-older-than "{{ duration }}" {{ args }}

# Deduplicate the store by hard linking (guide: nix-store --optimise).
optimise *args:
    @just --justfile "{{ justfile() }}" _exec nix-store --optimise {{ args }}

# GC roots: the system auto dir plus the user's state dir. Prune deletes dangling links only.
list-roots *args:
    @just --justfile "{{ justfile() }}" _exec ls -la /nix/var/nix/gcroots/auto "$HOME/.local/state/nix/gcroots" {{ args }}
prune-roots *args:
    @just --justfile "{{ justfile() }}" _exec find -L /nix/var/nix/gcroots/auto "$HOME/.local/state/nix/gcroots" -type l -delete {{ args }}

# The full sweep, as the primitives above in order — every step is runnable on its own.
# Root steps (rm-os, gc-old, optimise) only elevate when you pass --sudo.
sweep *args:
    #!/usr/bin/env bash
    set -uf pipefail
    arr=({{ args }})
    # A bare token is the duration, like `clean`'s bare scope; flags go to every step.
    duration=14d
    flags=()
    for a in "${arr[@]}"; do
        case "$a" in
        -*) flags+=("$a") ;;
        *) duration="$a" ;;
        esac
    done
    for step in expire-hm rm-user rm-os gc-old optimise; do
        case "$step" in
        expire-hm|rm-user|rm-os)
            just --justfile "{{ justfile() }}" "$step" "$duration" "${flags[@]}" || exit 1 ;;
        *)
            just --justfile "{{ justfile() }}" "$step" "${flags[@]}" || exit 1 ;;
        esac
    done

# --- nh clean ----------------------------------------------------------------
# nh's own cleanup bundle: generations + gcroots + direnv roots + store GC in one call. A bare
# token is the scope (`user`, `all` or `profile`, default `all`); --sudo elevates; --ask confirms
# unless you dry-run; `-k 3 -K 6h` is applied unless you pass your own `-k`/`-K`.

# scope x policy: gc = generations + gcroots + store GC; gen = generations only; opt/optf = gc
# plus `--optimise`, with or without `--keep-one` (nix.fish: nh_clean / nhcu / nhca / nhcuo / nhcao).
_clean scope="all" policy="gc" *args:
    #!/usr/bin/env bash
    set -uf pipefail
    arr=({{ args }})
    scope=all
    flags=()
    dry=false
    keep=false
    root=()
    for ((i = 0; i < ${#arr[@]}; i++)); do
        a="${arr[i]}"
        case "$a" in
        --sudo) root=(--sudo) ;;
        # nh's own dry-run flag is `--dry`; --ask is dropped because nothing asks in a dry run.
        --dry-run|--dry|-n) dry=true; flags+=(--dry) ;;
        --ask|-a) ;; # already the default
        --no-gc|--no-gcroots|--no-direnv|--optimise|--keep-one|--cross-filesystems|-q|-v|-x)
            flags+=("$a") ;;
        -k|--keep|-K|--keep-since)
            flags+=("$a" "${arr[i + 1]:-}"); keep=true; i=$((i + 1)) ;;
        --max|-e|--elevation-strategy)
            flags+=("$a" "${arr[i + 1]:-}"); i=$((i + 1)) ;;
        --*) flags+=("$a") ;;
        *) scope="$a" ;;
        esac
    done
    case "{{ policy }}" in
    gen)  flags+=(--no-gcroots --no-direnv) ;;
    gc)   ;;
    opt)  flags+=(--optimise --keep-one) ;;
    optf) flags+=(--optimise) ;;
    *) echo "Error: unknown clean policy '{{ policy }}'" >&2; exit 1 ;;
    esac
    [[ "$keep" == false ]] && flags+=(-k 3 -K 6h)
    [[ "$dry" == false ]] && flags+=(--ask)
    just --justfile "{{ justfile() }}" _exec nh clean "$scope" "${flags[@]}" "${root[@]}"

# Clean generations and gcroots (nix.fish: nh_clean); c?u = this user, c?a = every profile,
# cc = also `--optimise` the store, cc?f leaves `--keep-one` off.
clean *args: (_clean "all" "gc" args)
cu *args: (_clean "user" "gen" args)
ca *args: (_clean "all" "gen" args)
ccu *args: (_clean "user" "opt" args)
ccuf *args: (_clean "user" "optf" args)
cca *args: (_clean "all" "opt" args)
ccaf *args: (_clean "all" "optf" args)

# --- build -------------------------------------------------------------------
# nix.fish: _nfb + nix_build + nix_eval + _nix_dry_run, merged so the option set
# and the eval call exist once. `--sudo` is stripped and prefix-wrapped.
# The fast clients (nix-fast-build / nix-eval-jobs) were measured and culled: the
# Lix-linked evaluator holds a ~2.3GB floor whatever the host and spills swap, for
# ~4s saved on one host and *slower* on another. See DESIGN.md "What to run".

# Build a closure (--dry-run evaluates); links live under /tmp so a bare build never litters the cwd.
build attr out_link="{{ out_dir }}/nix-result" *args:
    #!/usr/bin/env bash
    set -uf pipefail
    args=()
    sudo=()
    dry=false
    for a in {{ args }}; do
        case "$a" in
        --sudo) sudo=({{ elev }}) ;;
        --dry-run) dry=true ;;
        *) args+=("$a") ;;
        esac
    done
    # `--dry-run` here is a real evaluation, not a printed plan, so this cannot go through _exec
    # (--dry-run there means "print it, run nothing"). The command is built as an array so the
    # quoted token in nix_opts stays one argument.
    if [[ "$dry" == true ]]; then
        export GC_INITIAL_HEAP_SIZE=2G
        echo "Evaluating {{ attr }} with nix build --dry-run..."
        cmd=(nix build {{ nix_opts }} --no-link --dry-run {{ attr }})
    else
        cmd=(nix build {{ nix_opts }} {{ attr }} --out-link {{ out_link }})
    fi
    "${sudo[@]}" "${cmd[@]}" "${args[@]}"

# Evaluate a flake attribute (nix.fish: nix_eval).
eval attr *args: (build attr "{{ out_dir }}/nix-eval-result" "--dry-run" args)

# --- activate / deploy -------------------------------------------------------
# nix.fish: _nix_switch_bin + _nix_remote_deploy.

# Resolve a built out-link to the store path of its closure. The link is the path
# `nix build --out-link` created, verbatim (the trailing `-` was nix-fast-build's
# prefix convention, which left with the client in 3e8ba15); `result`/`toplevel` are
# the shapes other clients leave behind. One place resolves a link — `_activate`,
# `_remote_activate` and `_push` all call this.
_resolve out_link:
    #!/usr/bin/env bash
    set -uf pipefail
    closure=$(realpath -e "{{ out_link }}/result" "{{ out_link }}/toplevel" "{{ out_link }}" 2>/dev/null | head -n 1)
    [[ -n "$closure" ]] || { echo "Error: no closure at {{ out_link }}" >&2; exit 1; }
    echo "$closure"

# Push a closure (and its dependency closure) to the xilo cache. Reached through
# `_deploy --with-xilo` (the built closure at the out-link) and mode `push` (the generation
# already active in a profile), so "push without rebuilding" is `njust os-push-active`.
#
# Credentials are hm-xilo's job: `xilo-wrapped` fills XILO_URL/XILO_TOKEN from credsctl
# records for whatever subcommand it runs, so this recipe never touches a secret — it only names
# the cache (the XILO_CACHE record if there is one, else xilo_cache). A 401 means the token is not
# live; `xilo-wrapped status` prints the profile, scope and expiry actually in use.
_push out_link cache=xilo_cache:
    #!/usr/bin/env bash
    set -uf pipefail
    command -v xilo-wrapped > /dev/null 2>&1 || { echo "Error: no xilo-wrapped on PATH — enable the hm-xilo feature to push" >&2; exit 1; }
    # `_resolve` prints its own error; a failed resolve must not continue with an empty path.
    closure=$(just --justfile "{{ justfile() }}" _resolve "{{ out_link }}") || exit 1
    target="{{ cache }}"
    status=0
    # credsctl owns the store location (CREDS_DIR, else CREDENTIALS_DIRECTORY, else systemd's
    # store), so the cache name is looked up with no path spelled here.
    val=$(credsctl decrypt XILO_CACHE) || status=$?
    # 2 = no such record, and a missing credsctl is the same thing here: the default cache name.
    # Anything else is a real decrypt failure and must not push to the wrong cache.
    [[ "$status" == 3 ]] && { echo "Error: cannot decrypt XILO_CACHE" >&2; exit 1; }
    [[ "$status" == 0 ]] && target="$val"
    xilo-wrapped push "$target" "$closure"

# Activate a built closure on THIS host. switch-to-configuration needs root; home-manager's
# activate takes no argument (it parses only --driver-version) and runs as the user, which
# updates the HM profile itself. --dry-run never gets here: _deploy stops first.
_activate out_link action="switch":
    #!/usr/bin/env bash
    set -uf pipefail
    # `_resolve` prints its own error; a failed resolve must not continue with an empty path.
    closure=$(just --justfile "{{ justfile() }}" _resolve "{{ out_link }}") || exit 1
    bin=$(realpath -e "$closure/bin/switch-to-configuration" "$closure/bin/activate" "$closure/activate" 2>/dev/null | head -n 1)
    [[ -n "$bin" ]] || { echo "Error: no switch binary in $closure" >&2; exit 1; }
    echo "Activating $closure ({{ action }})..."
    if [[ "$bin" == */switch-to-configuration ]]; then
        {{ elev }} nix-env --profile {{ sys_profile }} --set "$closure"
        {{ elev }} "$bin" {{ action }}
    else
        # home-manager's activate parses only --driver-version, so no argument here:
        # bare = driver version 0, which updates the HM profile itself, as the user.
        "$bin"
    fi

# Activate a built closure on a remote host: the closure is copied first, then activated over
# ssh. A remote closure is always a system one, and nothing here touches this host's profile.
_remote_activate out_link action remote:
    #!/usr/bin/env bash
    set -uf pipefail
    # `_resolve` prints its own error; a failed resolve must not continue with an empty path.
    closure=$(just --justfile "{{ justfile() }}" _resolve "{{ out_link }}") || exit 1
    bin=$(realpath -e "$closure/bin/switch-to-configuration" 2>/dev/null | head -n 1)
    [[ -n "$bin" ]] || { echo "Error: no switch-to-configuration in $closure" >&2; exit 1; }
    echo "Deploying $closure ({{ action }}) on {{ remote }}..."
    nix copy --to "ssh://{{ remote }}" "$closure"
    ssh -t "{{ remote }}" "sudo nix-env --profile {{ sys_profile }} --set $closure && sudo $bin {{ action }}"
    echo "  Manual switch on target: ssh {{ remote }} sudo $closure/bin/switch-to-configuration switch"

# Every deploy recipe is a scope x mode. Scope = what to build, where its out-link lives,
# and where it activates (a non-empty `remote` means over ssh). Mode = how far to go:
# build builds; switch/activate activate; boot/test set or check the next boot entry; push
# uploads the active generation and touches nothing else. Flags go to the nix client;
# --dry-run stops before activation. A flag's value(s) stay attached, so only a bare token
# that follows no flag is the target.
_deploy scope="hm" mode="switch" *args:
    #!/usr/bin/env bash
    set -uf pipefail
    arr=({{ args }})
    tgt=""
    flags=()
    dry=false
    push=false
    for ((i = 0; i < ${#arr[@]}; i++)); do
        a="${arr[i]}"
        case "$a" in
        # Collected here, forwarded only where something is built: the modes that build
        # nothing preview instead of passing a flag the client cannot use.
        --dry-run) dry=true ;;
        # Helper-level: push the built closure to the xilo cache, never a client flag.
        --with-xilo) push=true ;;
        # `build` strips `--sudo`; `rebuild` is already wrapped in sudo and nixos-rebuild
        # has no such flag, so it must not be forwarded there.
        --sudo) [[ "{{ scope }}" == rebuild ]] || flags+=("$a") ;;
        # Only flags `nix build` really takes a value for consume a token -- mirrors
        # `clean`. `--remote-ssh-option` is gone: `nix build` rejects it and the deploy
        # path hands flags to `build`, never to `nix copy`.
        --option|--override-input|--override-flake|--arg|--arg-from-file|--argstr)
            flags+=("$a" "${arr[i + 1]:-}" "${arr[i + 2]:-}"); i=$((i + 2)) ;;
        --out-link|--profile|--inputs-from|--eval-store|--include|--arg-from-stdin|--output-lock-file|--reference-lock-file|--update-input|--log-format)
            flags+=("$a" "${arr[i + 1]:-}"); i=$((i + 1)) ;;
        --*) flags+=("$a") ;;
        # Short flags follow the same rule: `nix build`'s -o/-I/-f and `nixos-rebuild`'s -p
        # take a value, -L (print-build-logs) and -v (verbose) do not. Without this branch a
        # bare `-L` was read as the target.
        -o|-I|-f|-p) flags+=("$a" "${arr[i + 1]:-}"); i=$((i + 1)) ;;
        -*) flags+=("$a") ;;
        *) tgt="$a" ;;
        esac
    done
    host="${tgt:-{{ hn }}}"
    # A mode is two facts: does it build, and does it activate. `push` is neither — it hands
    # the closure this host already has active to xilo and touches nothing else.
    builds=false
    activates=false
    action=""
    case "{{ mode }}" in
    build)     builds=true ;;
    switch)    builds=true; activates=true; action=switch ;;
    boot|test) builds=true; activates=true; action="{{ mode }}" ;;
    activate)  activates=true; action=switch ;;
    push)      push=true ;;
    *) echo "Error: unknown deploy mode '{{ mode }}'" >&2; exit 1 ;;
    esac
    # --dry-run is a client flag only where something is built; a mode that builds nothing
    # previews instead of forwarding a flag the client cannot use.
    [[ "$dry" == true && "$builds" == true ]] && flags+=("--dry-run")
    remote=""
    # `profile` is the active generation for this host's scope; "" where the scope activates
    # remotely, so there is nothing here to upload.
    case "{{ scope }}" in
    hm)        attr="{{ hm_root }}${tgt:-{{ me }}}{{ hm_attr }}"; link="{{ out_dir }}/{{ hm_link }}"; profile="{{ hm_profile }}" ;;
    os)        attr="{{ os_root }}$host{{ os_attr }}"; link="{{ out_dir }}/{{ os_link }}"; profile="{{ sys_profile }}" ;;
    os-deploy) attr="{{ os_root }}$host{{ os_attr }}"; link="{{ out_dir }}/{{ deploy_link }}"; remote="deployer@$host"; profile="" ;;
    nas)       attr="{{ nas_flake }}#nixosConfigurations.nasty{{ os_attr }}"; link="{{ out_dir }}/{{ deploy_link }}"; remote=homenas-deployer; profile="" ;;
    rebuild)   attr="{{ flake }}#$host"; link=""; profile="{{ sys_profile }}" ;;
    *) echo "Error: unknown deploy scope '{{ scope }}'" >&2; exit 1 ;;
    esac
    if [[ "{{ scope }}" == rebuild ]]; then
        # nixos-rebuild builds straight into the profile — there is no out-link to push.
        [[ "$push" == true ]] && { echo "Error: --with-xilo needs a build out-link; use 'njust os-build --with-xilo'" >&2; exit 1; }
        {{ elev }} nixos-rebuild --flake "$attr" {{ nix_opts }} "${flags[@]}"
        exit 0
    fi
    if [[ "{{ mode }}" == push ]]; then
        [[ -n "$profile" ]] || { echo "Error: mode 'push' uploads this host's active generation; scope '{{ scope }}' activates on a remote host" >&2; exit 1; }
        # A target would name a generation this host does not have active.
        [[ -n "$tgt" ]] && { echo "Error: mode 'push' uploads what is already active here; a target belongs to a build recipe" >&2; exit 1; }
        # The profile symlink, not the out-link: `_resolve` walks profile -> generation link ->
        # store path, so a push needs neither a build nor a /tmp link that a reboot can drop.
        link="$profile"
    fi
    # The action belongs to switch-to-configuration (system, needs root); home-manager's
    # activate takes none. `activate` is the switch a generation already built would do.
    if [[ "{{ scope }}" == hm ]]; then
        [[ "{{ mode }}" == boot || "{{ mode }}" == test ]] && { echo "Error: home-manager has no {{ mode }} action; use 'njust hm'" >&2; exit 1; }
        # Another host's home config evaluates fine, but activating it here would apply it
        # to this host. Building it is still allowed (hm-build / hm-push).
        [[ "$activates" == true && "$tgt" == *@* ]] && { echo "Error: home activation is local; '$tgt' is another host — build it with 'njust hm-build $tgt'" >&2; exit 1; }
        # home-manager's activate takes no argument and runs as the user; a build has
        # nothing to activate.
        [[ "$activates" == true ]] && action=activate
    fi
    if [[ "$builds" == false ]]; then
        # activate and push work on a generation that already exists: nothing is built, so
        # build flags would have nowhere to go.
        [[ ${#flags[@]} -gt 0 ]] && { echo "Error: mode '{{ mode }}' builds nothing; its flags belong to a build recipe" >&2; exit 1; }
    else
        # The NAS cache pair is appended (same order as nix.fish), so it wins over a
        # user-supplied --option extra-substituters.
        build_flags=("${flags[@]}")
        [[ "{{ scope }}" == nas ]] && build_flags+=({{ nas_cache }})
        if ! just --justfile "{{ justfile() }}" build "$attr" "$link" "${build_flags[@]}"; then
            # The hint is about *our* flake's host list, so it must not fire for the NAS,
            # which builds another flake and never takes a target.
            [[ "{{ scope }}" == os || "{{ scope }}" == os-deploy ]] && [[ -z "$tgt" ]] && echo "hint: default target '{{ hn }}' is not a nixosConfigurations host; \`njust info\` lists them, or pass one explicitly" >&2
            exit 1
        fi
    fi
    if [[ "$dry" == true ]]; then
        # The cache name is resolved by _push (it can come from the XILO_CACHE credential), so the
        # preview names the thing it will look up rather than a name it might not use.
        [[ "$push" == true ]] && echo "would push: $link → xilo cache (the name in the XILO_CACHE credential, else the default)"
        [[ -n "$action" ]] && echo "would activate: $link via $action${remote:+ on $remote}"
        exit 0
    fi
    # No `@` prefix: shebang recipes go to bash as one script, so just's per-line
    # prefixes are not processed here (`@just` would be a command named "@just").
    # Local and remote activation are separate paths: a remote closure is copied and
    # activated over ssh, and never touches this host's profile.
    if [[ -n "$action" ]]; then
        if [[ -n "$remote" ]]; then
            if ! just --justfile "{{ justfile() }}" _remote_activate "$link" "$action" "$remote"; then
                exit 1
            fi
        else
            if ! just --justfile "{{ justfile() }}" _activate "$link" "$action"; then
                exit 1
            fi
        fi
    fi
    # Push after activation: a cache push is a convenience, and a cache that rejects the
    # token must never stop your config from applying. Build-only modes push, no activation.
    if [[ "$push" == true ]]; then
        just --justfile "{{ justfile() }}" _push "$link" || { echo "Error: xilo push failed for $link" >&2; exit 1; }
    fi

# --- home-manager ------------------------------------------------------------
# scope hm: the user's home closure at the hm out-link, activated as the user. Home
# activation is a local thing — a user@host attribute builds, it never switches here.

# Home-manager closure for a user, built then activated locally (nix.fish: hm_fswitch).
hm *args: (_deploy "hm" "switch" args)

# Home-manager closure, built only — nothing is activated.
hm-build *args: (_deploy "hm" "build" args)

# Home-manager closure, built and pushed to the xilo cache — nothing is activated.
hm-push *args: (_deploy "hm" "build" "--with-xilo" args)

# Activate the home closure already built at the hm out-link — nothing is built.
hm-activate *args: (_deploy "hm" "activate" args)

# Push the home generation this host has active, from its profile — nothing is built or activated.
hm-push-active *args: (_deploy "hm" "push" args)

# Roll back the active home configuration (nix.fish: hmrb).
hm-rollback:
    home-manager switch --rollback --flake {{ flake }} {{ nix_opts }}

# Home-manager generations and their deletion (nix.fish: hmls / hmrm) are `_gens hm` now, so the
# spec guard and the client live in one place.

# --- nixos -------------------------------------------------------------------
# scope os: this host's config at the os out-link, activated as root. scope os-deploy/nas:
# the closure is copied to a remote host and activated there.

# NixOS closure for a host, built then switched locally (nix.fish: nixos_fswitch).
os-switch *args: (_deploy "os" "switch" args)

# NixOS closure, built then set as the next boot entry — not activated until reboot.
os-boot *args: (_deploy "os" "boot" args)

# NixOS closure, built then tested (switch-to-configuration test).
os-test *args: (_deploy "os" "test" args)

# NixOS closure, built only — nothing is activated.
os-build *args: (_deploy "os" "build" args)

# NixOS closure, built and pushed to the xilo cache — nothing is activated.
os-push *args: (_deploy "os" "build" "--with-xilo" args)

# Activate the NixOS closure already built at the os out-link — nothing is built.
os-activate *args: (_deploy "os" "activate" args)

# Push the system generation this host boots, from its profile — nothing is built or activated.
os-push-active *args: (_deploy "os" "push" args)

# Build, copy to a remote host, and set its next boot entry (nix.fish: nixos_fdeploy).
os-deploy *args: (_deploy "os-deploy" "boot" args)

# NAS deploy: nasty-config's flake + its Cachix cache via ssh alias homenas-deployer.
os-deploy-nas *args: (_deploy "nas" "boot" args)

# Plain nixos-rebuild (nixos-justnh / drs); its flags pass through. No mode: how far it goes is
# nixos-rebuild's own flag (--switch, --boot, --test), and it builds straight into the profile, so
# there is no out-link to activate or push.
# `mode` is unused for the rebuild scope — nixos-rebuild takes its own action flag — but just
# fills named parameters positionally, so a delegation has to supply something.
rebuild *args: (_deploy "rebuild" "switch" args)

# NixOS generations (nix.fish: nhdls / nhdrm) are `_gens os`: the elevation and the "no system
# profile here" guard live in that one place.
