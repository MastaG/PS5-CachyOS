#!/bin/sh
# PS5 CachyOS: add the newest Gaming Mode / Steam extras to an existing install (no reflash).
#
# Install:   curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-extras.sh | sudo sh
# Undo:      curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-extras.sh | sudo sh -s -- --rollback
#
# Adds:
#   - Gaming Mode launcher without -steamdeck (Steam no longer "updates" on every switch between
#     Gaming Mode and the desktop) and with the performance overlay (Steam menu -> Performance,
#     mangoapp).
#   - Desktop Steam starts with -steamos3 (Steam menu entry, desktop icon, game icons, autostart),
#     so desktop and Gaming Mode use the same Steam client build.
#   - Faster "Processing Vulkan shaders": Steam uses all 16 CPU threads (steam_dev.cfg).
#   - Refresh rate and resolution chosen in Steam itself (Settings -> Display), live, remembered
#     per screen; games see the real refresh rate. Replaces the old "Gaming Mode Refresh Rate" icon.
#   - HDR in Gaming Mode (quick menu -> Performance -> Enable HDR) on the PS5 Fat (FLAVA3 HDMI chip).
#     PS5 Slim (VERDE) keeps sRGB output without HDR.
#   - "12-bit Colour" desktop icon (sets the colour resolution to 12 bits, needed for HDR at 4K).
# Needs the SteamOS-style Gaming Mode of the 2026-11-10 image or newer. The Gaming Mode launcher
# /usr/bin/gamescope-session-ps5 is replaced only if it's a known image version (or with --force);
# the old one is kept as .bak-extras for --rollback.
# For the new kernel, FreeSync and 1080p 144 Hz, use update-kernel.sh.
set -eu

LAUNCHER=/usr/bin/gamescope-session-ps5
SHA_1110=40d3668d176a989f46740585cdbb0deb758d8c331e3468c26d8c6f4482cde692   # 2026-11-10 image
SHA_1114=f2ad02a6769246150b99bb62bef6d2d2b4fde25b55b7ab8b4827606d3edb0f19   # 2026-11-14 and 2026-11-17 images
SHA_MANGO=048a1c7d106f674ea48c826831e23f64e8a03e325568fff405b7d2c16dd8f50b  # 2026-11-18 live test (unconditional --mangoapp)
SHA_1119=49d2fce011746602c4669624afa078748cb7da07d83fd83a52adee4555b616b5   # 2026-11-19: no -steamdeck + mangoapp overlay
SHA_NEW=e0f8569765df67f4490fe28d3ca99d1b41d8054762909b1c3a991e131e7ad9b4    # + refresh rate in Steam, HDR (FLAVA3), WSI
SRGB_LUA_NAME=ps5-display.lua   # gamescope sRGB override in ~/.config/gamescope/scripts (needed on VERDE)
MENU=/usr/local/bin/ps5-gaming-mode-refresh
BIT12=/usr/local/bin/ps5-12bit-colour
SYS_STEAM=/usr/share/applications/steam.desktop
SHADER_LINE="unShaderBackgroundProcessingThreads 16"   # PS5: 8 cores / 16 threads on every model
URL=https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-extras.sh

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
APPS="$H/.local/share/applications"
OVR="$APPS/steam.desktop"
STEAMDIR="$H/.local/share/Steam"
DEVCFG="$STEAMDIR/steam_dev.cfg"
SRGB_LUA="$H/.config/gamescope/scripts/$SRGB_LUA_NAME"
# HDMI chip: FLAVA3 (PS5 Fat) does HDR; VERDE (PS5 Slim) needs the sRGB override.
IC=$(dmesg 2>/dev/null | sed -n 's/.*HDMI IC Type \[\([A-Za-z0-9]*\)\].*/\1/p' | head -1)
[ -n "$IC" ] || IC=$(journalctl -k -b 2>/dev/null | sed -n 's/.*HDMI IC Type \[\([A-Za-z0-9]*\)\].*/\1/p' | head -1)

udir() { su "$U" -s /bin/sh -c 'mkdir -p "$1"' _ "$1"; }   # make a folder owned by the user
# Steam launch lines in .desktop files: "Exec=steam ..." or "Exec=/usr/bin/steam ..."
STEAM_EXEC='^Exec=(/usr/bin/)?steam( |$)'
needs_steamos3() { grep -E "$STEAM_EXEC" "$1" 2>/dev/null | grep -qv -- '-steamos3'; }
add_steamos3() { sed -i -E "/-steamos3/!s#^(Exec=(/usr/bin/)?steam)( |\$)#\\1 -steamos3\\3#" "$1"; chown "$U:" "$1"; }
del_steamos3() { sed -i -E "s#^(Exec=(/usr/bin/)?steam) -steamos3( |\$)#\\1\\3#" "$1"; chown "$U:" "$1"; }
# Steam's own icons: game shortcuts, the Steam desktop icon, Steam autostart (our menu override is separate)
steam_icons() {
	for f in "$DESK"/*.desktop "$APPS"/*.desktop "$H/.config/autostart"/*.desktop; do
		[ -f "$f" ] && [ ! -L "$f" ] && [ "$f" != "$OVR" ] && echo "$f"
	done
}

if [ "${1:-}" = "--rollback" ]; then
	if [ -f "$LAUNCHER.bak-extras" ]; then
		mv "$LAUNCHER.bak-extras" "$LAUNCHER"
		echo "Previous Gaming Mode launcher restored."
		# the 2026-11-10 launcher has no refresh menu, so its icons go too
		if [ "$(sha256sum "$LAUNCHER" | cut -d' ' -f1)" = "$SHA_1110" ]; then
			rm -f "$MENU" "$BIT12" "$DESK/gaming-mode-refresh.desktop" "$DESK/12bit-colour.desktop"
			echo "Refresh rate and 12-bit colour icons removed."
		fi
	else
		echo "Gaming Mode launcher: no $LAUNCHER.bak-extras, left as it is."
	fi
	if [ -f "$SRGB_LUA.bak-extras" ] && [ ! -f "$SRGB_LUA" ]; then
		mv "$SRGB_LUA.bak-extras" "$SRGB_LUA" && echo "sRGB override for Gaming Mode restored (HDR off again)."
	fi
	if [ -f "$MENU.bak-extras" ] && [ ! -f "$MENU" ]; then
		mv "$MENU.bak-extras" "$MENU"
		[ -f "$DESK/gaming-mode-refresh.desktop.bak-extras" ] &&
			mv "$DESK/gaming-mode-refresh.desktop.bak-extras" "$DESK/gaming-mode-refresh.desktop"
		echo "Gaming Mode Refresh Rate icon restored."
	fi
	if [ -f "$OVR.bak-extras" ]; then
		mv "$OVR.bak-extras" "$OVR" && echo "Your own Steam menu entry restored."
	elif grep -qs '^X-PS5-CachyOS=steamos3' "$OVR"; then
		rm -f "$OVR" && echo "Steam menu entry back to the normal one (without -steamos3)."
	fi
	steam_icons | while IFS= read -r f; do
		if grep -qE '^Exec=(/usr/bin/)?steam -steamos3( |$)' "$f"; then del_steamos3 "$f"; echo "Removed -steamos3 from $f"; fi
	done
	if [ -f "$DEVCFG.bak-extras" ]; then
		mv "$DEVCFG.bak-extras" "$DEVCFG" && echo "Your own steam_dev.cfg restored."
	elif [ "$(cat "$DEVCFG" 2>/dev/null)" = "$SHADER_LINE" ]; then
		rm -f "$DEVCFG" && echo "Shader threads setting removed (Steam default again)."
	fi
	sync
	echo "Undone."
	exit 0
fi

[ -f "$LAUNCHER" ] && [ -x /usr/bin/steamos-session-select ] && [ -x /usr/local/bin/ps5-warm-desktop ] ||
	die "this install doesn't have the SteamOS-style Gaming Mode of the 2026-11-10 image. Nothing changed."

sha=$(sha256sum "$LAUNCHER" | cut -d' ' -f1)
replace=no
case "$sha" in
	"$SHA_NEW") echo "Gaming Mode launcher is already the newest one." ;;
	"$SHA_1110"|"$SHA_1114"|"$SHA_MANGO"|"$SHA_1119") replace=yes ;;
	*)
		if [ "${1:-}" = "--force" ]; then
			replace=yes
		else
			echo "Gaming Mode launcher: SKIPPED, left as it is."
			echo "  $LAUNCHER is not one of the known versions (2026-11-10 to 2026-11-19)"
			echo "  (sha256: $sha),"
			echo "  so it was probably edited by hand. To replace it anyway with the newest one"
			echo "  (refresh rate in Steam, HDR, performance overlay; yours is kept as .bak-extras):"
			echo "    curl -fsSL $URL | sudo sh -s -- --force"
			echo "  The other extras below are installed either way."
		fi
		;;
esac
if [ "$replace" = yes ]; then
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
#   --sdr-gamut-wideness 0   : SDR content stays sRGB (no oversaturated colours)
#   --xwayland-count 2       : Steam gets its own Xwayland, as on SteamOS (Steam's display
#                              settings then show the mode that is really in use)
#
# PS5 Slim (VERDE HDMI chip): ~/.config/gamescope/scripts/ps5-display.lua forces sRGB,
# because BT2020/HDR signalling gives a black screen there. Without that script (PS5 Fat,
# FLAVA3) Steam's HDR switch is offered.

export LIBSEAT_BACKEND=logind
export WLR_LIBINPUT_NO_DEVICES=1

# Steam UI options, as in SteamOS's gamescope session.
# Performance overlay (Steam menu -> Performance): mangoapp, toggled from inside Gaming Mode.
export STEAM_USE_MANGOAPP=1
export STEAM_MANGOAPP_PRESETS_SUPPORTED=1
export STEAM_MANGOAPP_HORIZONTAL_SUPPORTED=1
export MANGOHUD_CONFIGFILE="${XDG_RUNTIME_DIR:-/tmp}/mangohud-gamescope.conf"
echo "no_display" > "$MANGOHUD_CONFIGFILE"   # hidden until turned on in the Steam menu
export STEAM_GAMESCOPE_VRR_SUPPORTED=1
export STEAM_GAMESCOPE_HAS_TEARING_SUPPORT=1
export STEAM_GAMESCOPE_TEARING_SUPPORTED=1
export STEAM_GAMESCOPE_NIS_SUPPORTED=1
export STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT=1
export STEAM_GAMESCOPE_COLOR_MANAGED=1
export STEAM_GAMESCOPE_VIRTUAL_WHITE=1
export STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER=1
export STEAM_MULTIPLE_XWAYLANDS=1
# Refresh rate / resolution picker in Steam (Settings -> Display): gamescope lists the
# screen's modes and remembers the chosen one per screen.
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/gamescope"
export GAMESCOPE_MODE_SAVE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gamescope/modes.cfg"
export GAMESCOPE_PATCHED_EDID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gamescope/edid.bin"
# Games see the real refresh rate (gamescope's Vulkan WSI layer).
export ENABLE_GAMESCOPE_WSI=1
# HDR switch in Steam, unless the sRGB override is in place (PS5 Slim).
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/gamescope/scripts/ps5-display.lua" ] ||
    export STEAM_GAMESCOPE_HDR_SUPPORTED=1

# Launch flags:
#   -gamepadui  : controller-friendly Steam UI (Big Picture-like)
#   -steamos3 -steampal : SteamOS-style UI (Switch to Desktop, display
#                   settings). OS update checks are answered by the
#                   /usr/bin/steamos-update stub ("no update"); use pacman for updates.
#   (-steamdeck removed 2026-11-18: it switched Steam to the Deck client build and
#    desktop Steam switched it back, so Steam "updated" on every mode switch.)
MANGO_ARGS=
command -v mangoapp >/dev/null 2>&1 && MANGO_ARGS="--mangoapp"

/usr/bin/gamescope \
    --backend drm \
    -e \
    --prefer-output DP-1 \
    --sdr-gamut-wideness 0 \
    --xwayland-count 2 \
    $MANGO_ARGS \
    -- \
    /usr/bin/steam -gamepadui -steamos3 -steampal

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
	[ "$(sha256sum "$LAUNCHER.new" | cut -d' ' -f1)" = "$SHA_NEW" ] ||
		{ rm -f "$LAUNCHER.new"; die "the new launcher came out wrong (download cut off?). Nothing changed."; }
	chmod 755 "$LAUNCHER.new"
	mv "$LAUNCHER.new" "$LAUNCHER"
	echo "Gaming Mode: refresh rate in Steam's display settings, performance overlay, no Steam update loop."
fi

# HDR in Gaming Mode: only without the sRGB override, and only on FLAVA3 (PS5 Fat).
if [ "$IC" = FLAVA3 ] && [ -f "$SRGB_LUA" ]; then
	mv "$SRGB_LUA" "$SRGB_LUA.bak-extras"
	echo "Gaming Mode HDR: enabled for the FLAVA3 HDMI chip (sRGB override kept as $SRGB_LUA_NAME.bak-extras)."
elif [ "$IC" = FLAVA3 ]; then
	echo "Gaming Mode HDR: already enabled."
else
	echo "Gaming Mode HDR: not enabled (HDMI chip: ${IC:-unknown}; HDR needs FLAVA3, PS5 Slim stays on sRGB)."
fi

# Desktop Steam with -steamos3: same Steam client build as Gaming Mode, so switching modes no
# longer makes Steam "update". Menu entry = a copy of the system one in ~/.local/share/applications.
if [ -f "$SYS_STEAM" ]; then
	udir "$APPS"
	if [ -f "$OVR" ] && ! needs_steamos3 "$OVR"; then
		echo "Steam menu entry already starts Steam with -steamos3."
	elif [ -f "$OVR" ]; then
		cp -p "$OVR" "$OVR.bak-extras"   # the user's own override: keep it for --rollback
		add_steamos3 "$OVR"
		echo "Steam menu entry: added -steamos3 (yours kept as steam.desktop.bak-extras)."
	else
		sed '0,/^\[Desktop Entry\]$/s//&\nX-PS5-CachyOS=steamos3/' "$SYS_STEAM" > "$OVR"
		add_steamos3 "$OVR"
		echo "Steam menu entry: desktop Steam now starts with -steamos3."
	fi
	# a desktop icon linked to the system entry -> link it to the new one
	if [ -L "$DESK/steam.desktop" ] && [ "$(readlink -f "$DESK/steam.desktop")" = "$SYS_STEAM" ]; then
		ln -sfn "$OVR" "$DESK/steam.desktop" && chown -h "$U:" "$DESK/steam.desktop"
	fi
fi
steam_icons | while IFS= read -r f; do
	if needs_steamos3 "$f"; then add_steamos3 "$f"; echo "Added -steamos3 to $f"; fi
done

# Faster "Processing Vulkan shaders": shader pre-caching on all 16 threads (Arch Wiki).
if grep -qs '^unShaderBackgroundProcessingThreads' "$DEVCFG"; then
	echo "Shader threads already set in steam_dev.cfg (kept as it is)."
else
	if [ -f "$DEVCFG" ]; then
		cp -p "$DEVCFG" "$DEVCFG.bak-extras"
		[ -s "$DEVCFG" ] && [ -n "$(tail -c1 "$DEVCFG")" ] && echo >> "$DEVCFG"
	else
		udir "$STEAMDIR"
	fi
	echo "$SHADER_LINE" >> "$DEVCFG"
	chown "$U:" "$DEVCFG"
	echo "Steam shader pre-caching now uses all 16 CPU threads."
fi

# The old "Gaming Mode Refresh Rate" icon only set gamescope's -r, which Steam's own refresh rate
# setting now replaces (and -r blocked it). Keep the old files for --rollback.
if [ -f "$MENU" ]; then
	mv "$MENU" "$MENU.bak-extras"
	[ -f "$DESK/gaming-mode-refresh.desktop" ] &&
		mv "$DESK/gaming-mode-refresh.desktop" "$DESK/gaming-mode-refresh.desktop.bak-extras"
	echo "Gaming Mode Refresh Rate icon removed: choose the refresh rate in Steam -> Settings -> Display."
fi

echo "Installing the 12-bit colour script..."
	cat > "$BIT12" <<'PS5EOF'
#!/bin/sh
# Set KDE's colour resolution for the PS5 HDMI output (DP-1) to 12 bits (needed for HDR at 4K).
if kscreen-doctor output.DP-1.maxbpc.12 >/dev/null 2>&1; then
    notify-send -i preferences-desktop-display "12-bit colour" "Colour resolution set to 12 bits. HDR now also works at 4K."
else
    notify-send -i dialog-error "12-bit colour" "Could not set 12-bit colour on DP-1. 12-bit colour is not supported on PS5 Slim (VERDE HDMI chip)."
fi
PS5EOF
chmod 755 "$BIT12"

echo "Adding the desktop icons to $DESK..."
udir "$DESK"
	cat > "$DESK/12bit-colour.desktop" <<'PS5EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=12-bit Colour
Comment=Set the display's colour resolution to 12 bits (needed for HDR at 4K). Not supported on PS5 Slim (VERDE HDMI chip)
Exec=/usr/local/bin/ps5-12bit-colour
Icon=preferences-desktop-display
Terminal=false
Categories=Settings;
PS5EOF
chown "$U:" "$DESK/12bit-colour.desktop"
chmod 755 "$DESK/12bit-colour.desktop"
sync

echo
echo "Done. You now have:"
echo "  - Gaming Mode without the Steam update loop, and a performance overlay (Steam menu ->"
echo "    Performance) if the launcher was updated above."
echo "  - Desktop Steam on the same client build as Gaming Mode (restart Steam if it's open)."
echo "  - Faster shader pre-caching (all 16 threads)."
echo "  - Refresh rate in Steam -> Settings -> Display (also live, in Gaming Mode)."
echo "  - HDR in Gaming Mode (quick menu -> Performance) on the PS5 Fat."
echo "  - 12-bit Colour icon on the desktop."
echo "If KDE asks whether to trust an icon the first time you click it, choose 'Continue'."
echo "Undo with:"
echo "  curl -fsSL $URL | sudo sh -s -- --rollback"
