# Which desktop manager owns the graphical session, read from upstream
# services options. Home Manager cannot see NixOS state, so every DE-specific
# niri/dms setting lives NixOS-side and asks this instead of assuming Plasma.
# ponytail: no override option; add one only if a host ever needs to force a DE.
{config}:
if config.services.desktopManager.plasma6.enable
then "kde"
else if config.services.desktopManager.gnome.enable
then "gnome"
else "none"
