#!/bin/sh
# PS5 CachyOS: add the extras from the 2026-11-14 image to an existing install (no reflash).
#
# Install:   curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-extras.sh | sudo sh
# Undo:      curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-extras.sh | sudo sh -s -- --rollback
#
# Adds:
#   - Gaming Mode refresh rate menu: "Gaming Mode Refresh Rate" desktop icon (144 / 120 for
#     FreeSync / 60 / monitor default). Gaming Mode starts at 144 Hz until you pick something else.
#   - "12-bit Colour" desktop icon (sets the colour resolution to 12 bits, needed for HDR at 4K).
# For the 2026-11-10 image (needs its SteamOS-style Gaming Mode). The Gaming Mode launcher
# /usr/bin/gamescope-session-ps5 is replaced; the old one is kept as .bak-extras for --rollback.
# For the new kernel, FreeSync and 1080p 144 Hz, use update-kernel.sh.
set -eu

LAUNCHER=/usr/bin/gamescope-session-ps5
SHA_OLD=40d3668d176a989f46740585cdbb0deb758d8c331e3468c26d8c6f4482cde692   # 2026-11-10 image
SHA_NEW=f2ad02a6769246150b99bb62bef6d2d2b4fde25b55b7ab8b4827606d3edb0f19   # 2026-11-14 image
MENU=/usr/local/bin/ps5-gaming-mode-refresh
BIT12=/usr/local/bin/ps5-12bit-colour

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo (see the top of this script)."
grep -q 'console=ttyTitania0' /proc/cmdline || die "this doesn't look like Linux on a PS5. Nothing changed."

# The desktop user: whoever ran sudo, else the tty1 autologin user, else steam.
U=${SUDO_USER:-}
if [ -z "$U" ] || [ "$U" = root ]; then
	U=$(sed -n 's/.*--autologin \([^ ]*\).*/\1/p' /etc/systemd/system/getty@tty1.service.d/*.conf 2>/dev/null | head -1)
fi
[ -n "$U" ] || U=steam
H=$(getent passwd "$U" | cut -d: -f6)
[ -n "$H" ] && [ -d "$H" ] || die "can't find the home folder of user '$U'. Nothing changed."
DESK=$(su "$U" -c 'xdg-user-dir DESKTOP' 2>/dev/null || true)
[ -n "$DESK" ] && [ "$DESK" != "$H" ] || DESK="$H/Desktop"

if [ "${1:-}" = "--rollback" ]; then
	[ -f "$LAUNCHER.bak-extras" ] || die "no $LAUNCHER.bak-extras found, nothing to undo."
	mv "$LAUNCHER.bak-extras" "$LAUNCHER"
	rm -f "$MENU" "$BIT12" "$DESK/gaming-mode-refresh.desktop" "$DESK/12bit-colour.desktop"
	sync
	echo "Undone: the previous Gaming Mode launcher is back, the two desktop icons are removed."
	exit 0
fi

[ -f "$LAUNCHER" ] && [ -x /usr/bin/steamos-session-select ] && [ -x /usr/local/bin/ps5-warm-desktop ] ||
	die "this install doesn't have the SteamOS-style Gaming Mode of the 2026-11-10 image. Nothing changed."

sha=$(sha256sum "$LAUNCHER" | cut -d' ' -f1)
if [ "$sha" = "$SHA_NEW" ]; then
	echo "Gaming Mode launcher already has the refresh rate menu."
elif [ "$sha" = "$SHA_OLD" ] || [ "${1:-}" = "--force" ]; then
	echo "Updating the Gaming Mode launcher (old one kept as $LAUNCHER.bak-extras)..."
	cp -p "$LAUNCHER" "$LAUNCHER.bak-extras"
	cat > "$LAUNCHER.new" <<'PS5EOF'
#!/bin/bash
# PS5 gamescope session launcher — invoked by tty1 (ps5-tty-session.sh).
#
# All flags are PS5-specific workarounds:
#   LIBSEAT_BACKEND=logind   : avoids seatd/logind conflict; matches the user
#                              session so gamescope can take DRM/input devices
#                              via logind TakeDevice()
#   WLR_LIBINPUT_NO_DEVICES=1: suppresses libinput "no input devices" abort;
#                              PS5 has no directly-attached HID devices on boot
#   --backend drm            : take the DRM device directly (no nested compositor)
#   -e                       : embedded / Steam Big Picture mode
#   --prefer-output DP-1     : target the PS5's internal DP connector
#   --sdr-gamut-wideness 0   : keep SDR colour space at sRGB; the PS5's internal
#                              DP->HDMI bridge cannot translate BT2020 signalling
#
# The ps5-display.lua script in ~/.config/gamescope/scripts/ enforces sRGB
# colorimetry at the DRM atomic commit level (belt-and-suspenders with the flag).

export LIBSEAT_BACKEND=logind
export WLR_LIBINPUT_NO_DEVICES=1

# Steam UI options, same as Bazzite's session (HDR and mangoapp deliberately left out).
export STEAM_GAMESCOPE_VRR_SUPPORTED=1
export STEAM_GAMESCOPE_HAS_TEARING_SUPPORT=1
export STEAM_GAMESCOPE_TEARING_SUPPORTED=1
export STEAM_GAMESCOPE_NIS_SUPPORTED=1
export STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT=1
export STEAM_GAMESCOPE_COLOR_MANAGED=1
export STEAM_GAMESCOPE_VIRTUAL_WHITE=1

# Launch flags:
#   -gamepadui  : controller-friendly Steam UI (Big Picture-like)
#   -steamos3 -steampal -steamdeck : SteamOS-style UI (Switch to Desktop, display
#                   settings), as on Bazzite. OS update checks are answered by the
#                   /usr/bin/steamos-update stub ("no update"); use pacman for updates.
# Gaming Mode refresh rate, chosen with the "Gaming Mode Refresh Rate" desktop icon
# (saved in ~/.config/ps5-gaming-mode.conf). Only the refresh rate is passed, so gamescope
# keeps the screen's native resolution and picks the closest supported rate.
# Empty = the monitor's default mode (usually 60 Hz).
PS5_GM_REFRESH=144
PS5_GM_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ps5-gaming-mode.conf"
if [ -r "$PS5_GM_CONF" ]; then
    PS5_GM_REFRESH=$(sed -n 's/^PS5_GM_REFRESH=\([0-9]*\)$/\1/p' "$PS5_GM_CONF" | tail -1)
fi
REFRESH_ARGS=
[ -n "$PS5_GM_REFRESH" ] && REFRESH_ARGS="-r $PS5_GM_REFRESH"

/usr/bin/gamescope \
    --backend drm \
    -e \
    --prefer-output DP-1 \
    $REFRESH_ARGS \
    --sdr-gamut-wideness 0 \
    -- \
    /usr/bin/steam -gamepadui -steamos3 -steampal -steamdeck

# Fallback from before -steamos3 was added, when "Switch to Desktop" did not call steamos-session-select:
# Steam just quits, and gamescope often aborts on the way out ("Failed to pin
# framebuffer -12"). tty1 then respawned straight back into gamescope. So whenever
# gamescope ends (switch, exit or crash), do the warm restart into Plasma
# (ps5-warm-desktop via steamos-session-select), unless the system is shutting down.
# Back to Gaming Mode: the "Return to Gaming Mode" desktop shortcut.
state=$(systemctl is-system-running 2>/dev/null || true)
case "$state" in
    stopping|offline) exit 0 ;;
esac
exec /usr/bin/steamos-session-select plasma
PS5EOF
	chmod 755 "$LAUNCHER.new"
	mv "$LAUNCHER.new" "$LAUNCHER"
else
	die "$LAUNCHER has been changed by hand (not the 2026-11-10 version), so it was left alone.
       Re-run with '--force' to replace it anyway (yours is kept as .bak-extras). Nothing changed."
fi

echo "Installing the refresh rate menu and the 12-bit colour script..."
	cat > "$MENU" <<'PS5EOF'
#!/bin/sh
# Choose the refresh rate Gaming Mode starts with. Read by /usr/bin/gamescope-session-ps5.
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ps5-gaming-mode.conf"
cur=144
[ -r "$CONF" ] && cur=$(sed -n 's/^PS5_GM_REFRESH=\([0-9]*\)$/\1/p' "$CONF" | tail -1)
echo "Gaming Mode refresh rate (now: ${cur:-monitor default})"
echo
echo "  1) Highest, 144 Hz (60 Hz screens get 60, 120 Hz TVs get 120)"
echo "  2) 120 Hz (use this for FreeSync / VRR)"
echo "  3) 60 Hz"
echo "  4) Monitor default"
echo
printf 'Choice [1-4]: '
read c
case "$c" in
    1) v=144 ;; 2) v=120 ;; 3) v=60 ;; 4) v= ;;
    *) echo "No change."; printf 'Press Enter to close'; read _; exit 0 ;;
esac
mkdir -p "$(dirname "$CONF")"
echo "PS5_GM_REFRESH=$v" > "$CONF"
echo "Saved: ${v:+$v Hz}${v:-monitor default}. Used the next time Gaming Mode starts."
printf 'Switch to Gaming Mode now? [y/N] '
read a
case "$a" in y|Y) steamos-session-select gamescope ;; esac
PS5EOF
	cat > "$BIT12" <<'PS5EOF'
#!/bin/sh
# Set KDE's colour resolution for the PS5 HDMI output (DP-1) to 12 bits (needed for HDR at 4K).
if kscreen-doctor output.DP-1.maxbpc.12 >/dev/null 2>&1; then
    notify-send -i preferences-desktop-display "12-bit colour" "Colour resolution set to 12 bits. HDR now also works at 4K."
else
    notify-send -i dialog-error "12-bit colour" "Could not set 12-bit colour on DP-1."
fi
PS5EOF
chmod 755 "$MENU" "$BIT12"

echo "Adding the desktop icons to $DESK..."
mkdir -p "$DESK"
	cat > "$DESK/gaming-mode-refresh.desktop" <<'PS5EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Gaming Mode Refresh Rate
Comment=Choose the refresh rate Gaming Mode starts with (144, 120 for FreeSync, 60, or monitor default)
Exec=konsole -e /usr/local/bin/ps5-gaming-mode-refresh
Icon=preferences-desktop-display
Terminal=false
Categories=Settings;
PS5EOF
	cat > "$DESK/12bit-colour.desktop" <<'PS5EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=12-bit Colour
Comment=Set the display's colour resolution to 12 bits (needed for HDR at 4K)
Exec=/usr/local/bin/ps5-12bit-colour
Icon=preferences-desktop-display
Terminal=false
Categories=Settings;
PS5EOF
chown "$U:" "$DESK" "$DESK/gaming-mode-refresh.desktop" "$DESK/12bit-colour.desktop"
chmod 755 "$DESK/gaming-mode-refresh.desktop" "$DESK/12bit-colour.desktop"
sync

echo
echo "Done. On the desktop you now have:"
echo "  - Gaming Mode Refresh Rate: pick 144, 120 (FreeSync), 60 Hz or the monitor default."
echo "    Gaming Mode starts at 144 Hz until you choose something else."
echo "  - 12-bit Colour: sets 12-bit colour (needed for HDR at 4K)."
echo "If KDE asks whether to trust an icon the first time you click it, choose 'Continue'."
echo "Undo with:"
echo "  curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-extras.sh | sudo sh -s -- --rollback"
