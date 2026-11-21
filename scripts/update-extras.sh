#!/bin/sh
# PS5 CachyOS: add the newest Gaming Mode / Steam extras to an existing install (no reflash).
#
# Install:   curl -fsSL https://raw.githubusercontent.com/MastaG/PS5-CachyOS/main/scripts/update-extras.sh | sudo sh
# Undo:      curl -fsSL https://raw.githubusercontent.com/MastaG/PS5-CachyOS/main/scripts/update-extras.sh | sudo sh -s -- --rollback
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
#   - HDR in Gaming Mode (quick menu -> Performance -> Enable HDR) on the PS5 Fat and Pro (FLAVA3 HDMI chip).
#     PS5 Slim (VERDE) keeps sRGB output without HDR.
#   - "12-bit Colour" desktop icon (sets the colour resolution to 12 bits, needed for HDR at 4K).
#   - Faster DualSense reconnects (Bluetooth fast connectable).
#   - PS5 OS pairing import (ps5-bt-sync): controllers paired in PS5 OS also work in Linux, with a
#     loader that exports them.
#   - PS5 Pro internal Bluetooth services (needs kernel 7.3.5-pc8fe or newer).
#   - "Gaming Mode" / "Desktop" picture instead of console text while switching modes.
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
SHA_NEW_UNIT=13d0ecbb2ccd1cf340d431176394531e4b75409ce578f430792e14ada8e16d38  # SHA_NEW, Steam as a user unit (ps5-steam-session)
STEAM_LINE='    /usr/bin/steam -gamepadui -steamos3 -steampal'
UNIT_LINE='    /usr/local/bin/ps5-steam-session'
SRGB_LUA_NAME=ps5-display.lua   # gamescope sRGB override in ~/.config/gamescope/scripts (needed on VERDE)
MENU=/usr/local/bin/ps5-gaming-mode-refresh
BIT12=/usr/local/bin/ps5-12bit-colour
SYS_STEAM=/usr/share/applications/steam.desktop
SHADER_LINE="unShaderBackgroundProcessingThreads 16"   # PS5: 8 cores / 16 threads on every model
URL=https://raw.githubusercontent.com/MastaG/PS5-CachyOS/main/scripts/update-extras.sh
FILES=https://raw.githubusercontent.com/MastaG/PS5-CachyOS/main/files
BTCONF=/etc/bluetooth/main.conf
VIOLA_FILES="etc/udev/rules.d/50-viola-bt-power.rules etc/modprobe.d/viola-btusb.conf
 usr/local/sbin/ps5-viola-bt-reset etc/systemd/system/ps5-viola-bt-reset.service
 usr/local/sbin/ps5-viola-bt-revive etc/systemd/system/ps5-viola-bt-revive.service"
SPLASH_FILES="usr/local/bin/ps5-splash usr/local/share/ps5-splash/gaming.png usr/local/share/ps5-splash/desktop.png"
SPLASH_HOOKED="/usr/local/bin/ps5-warm-desktop /usr/bin/steamos-session-select /etc/profile.d/ps5-tty-session.sh"
SYNC=/usr/local/libexec/ps5-bt-sync
SYNC_URL=https://raw.githubusercontent.com/ps5-linux/ps5-linux-patches/c8fe83a/bluetooth/ps5-bt-sync
SYNC_SHA=1b79c9cd8059d1f4e3757bb78b64f8aa53003dfcb5190bb752b7b5a879fa40ee

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
# HDMI chip: FLAVA3 (PS5 Fat and Pro) does HDR; VERDE (PS5 Slim) needs the sRGB override.
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

# get <path>: download files/<path> from this repo to /<path>
get() {
	mkdir -p "$(dirname "/$1")"
	curl -fsSL --max-time 60 -o "/$1.new" "$FILES/$1" && mv -f "/$1.new" "/$1" || { rm -f "/$1.new"; return 1; }
}
# lines in <file> containing the fixed string <text>
count() { awk -v s="$2" 'index($0, s) { n++ } END { print n + 0 }' "$1"; }
# insert <line> after the one line containing <anchor> (or before the last one: mode "beforelast")
insert() { # insert file anchor after|beforelast line
	awk -v s="$2" -v m="$3" -v t="$4" -v n="$(count "$1" "$2")" '
		index($0, s) { c++; if (m == "beforelast" && c == n) print t; print; if (m == "after" && c == 1) print t; next }
		{ print }' "$1" > "$1.tmp" && cat "$1.tmp" > "$1" && rm -f "$1.tmp"
}
# hook <file> <anchor> after <line>: add a switch-picture line, once, if the anchor is there exactly once
hook() {
	[ -f "$1" ] || return 1
	grep -q ps5-splash "$1" && return 0
	[ "$(count "$1" "$2")" = 1 ] || { echo "  $1: not the image's version, switch picture not added there."; return 1; }
	cp -p "$1" "$1.bak-extras"
	insert "$1" "$2" "$3" "$4"
}
# the tty1 session script: picture on Gaming -> Desktop, and after Desktop -> Gaming
hook_tty() {
	f=/etc/profile.d/ps5-tty-session.sh
	[ -f "$f" ] || return 1
	grep -q ps5-splash "$f" && return 0
	if [ "$(count "$f" 'LOG=/tmp/ps5-tty-session.log')" != 1 ] || [ "$(count "$f" 'unset PS5_TTY_SESSION_INIT')" != 1 ] ||
	   [ "$(count "$f" 'exec /usr/bin/gamescope-session-ps5')" != 2 ]; then
		echo "  $f: not the image's version, switch picture not added there."; return 1
	fi
	cp -p "$f" "$f.bak-extras"
	insert "$f" 'LOG=/tmp/ps5-tty-session.log' after \
		'    # Switch picture (Gaming -> Desktop) instead of console text.\n    [ -x /usr/local/bin/ps5-splash ] && /usr/local/bin/ps5-splash desktop'
	insert "$f" 'unset PS5_TTY_SESSION_INIT' after '    [ -x /usr/local/bin/ps5-splash ] && /usr/local/bin/ps5-splash gaming'
	insert "$f" 'exec /usr/bin/gamescope-session-ps5' beforelast \
		'    # After a Desktop -> Gaming switch (not at boot): draw the Gaming Mode picture and\n    # send gamescope/Steam output to a log so no text is printed over it.\n    if [ -x /usr/local/bin/ps5-splash ] && [ -f "/tmp/ps5-splash-pending-$(id -u)" ]; then\n      /usr/local/bin/ps5-splash --pending\n      exec /usr/bin/gamescope-session-ps5 >/tmp/ps5-gamescope-session.log 2>&1\n    fi'
}

if [ "${1:-}" = "--rollback" ]; then
	for f in $SPLASH_HOOKED; do
		[ -f "$f.bak-extras" ] && grep -qs ps5-splash "$f" && mv "$f.bak-extras" "$f" && echo "Switch picture removed from $f."
	done
	rm -rf /usr/local/bin/ps5-splash /usr/local/share/ps5-splash
	if [ -f "$BTCONF.bak-extras" ]; then
		mv "$BTCONF.bak-extras" "$BTCONF" && echo "Bluetooth settings restored (fast connectable off)."
	fi
	if grep -qs 'PS5-CachyOS update-extras' /etc/systemd/system/ps5-bt-sync.service; then
		systemctl disable -q ps5-bt-sync.service 2>/dev/null || true
		rm -f /etc/systemd/system/ps5-bt-sync.service "$SYNC"
		grep -qs 'PS5-CachyOS update-extras' /etc/ps5-bt-sync.conf && rm -f /etc/ps5-bt-sync.conf
		echo "PS5 OS pairing import removed (pairings already imported stay)."
	fi
	systemctl daemon-reload
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
	"$SHA_NEW_UNIT") echo "Gaming Mode launcher is already the newest one." ;;
	"$SHA_NEW") [ -x /usr/local/bin/ps5-steam-session ] && replace=yes || echo "Gaming Mode launcher is already the newest one." ;;
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
	# This fork: Steam runs as steam-launcher.service (ps5-steam-session), so KytyPS5 can unload it.
	if [ -x /usr/local/bin/ps5-steam-session ]; then
		sed -i "s|^$STEAM_LINE\$|$UNIT_LINE|" "$LAUNCHER.new"
		[ "$(sha256sum "$LAUNCHER.new" | cut -d' ' -f1)" = "$SHA_NEW_UNIT" ] ||
			{ rm -f "$LAUNCHER.new"; die "the Steam unit change didn't apply to the new launcher. Nothing changed."; }
	fi
	chmod 755 "$LAUNCHER.new"
	mv "$LAUNCHER.new" "$LAUNCHER"
	echo "Gaming Mode: refresh rate in Steam's display settings, performance overlay, no Steam update loop."
fi

# HDR in Gaming Mode: only without the sRGB override, and only on FLAVA3 (PS5 Fat and Pro).
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

# Bluetooth: fast connectable (page scan every 160 ms instead of 1.28 s), so a DualSense
# reconnects in about a second. On the PS5 Pro it's needed, because PS5 OS's Bluetooth
# function (same address) otherwise often catches the controller first.
if [ -f "$BTCONF" ]; then
	if grep -q '^FastConnectable *= *true' "$BTCONF"; then
		echo "Bluetooth fast connectable: already on."
	else
		cp -p "$BTCONF" "$BTCONF.bak-extras"
		if grep -q '^#\?FastConnectable' "$BTCONF"; then
			sed -i 's/^#\?FastConnectable *=.*/FastConnectable = true/' "$BTCONF"
		else
			sed -i '/^\[General\]/a FastConnectable = true' "$BTCONF"
		fi
		echo "Bluetooth: fast connectable on (the DualSense reconnects faster; active after a restart)."
	fi
fi

# PS5 Pro internal Bluetooth (0e8d:3605, needs kernel 7.3.5-pc8fe or newer): no USB autosuspend,
# reset once after the handoff from PS5 OS, revive if the adapter didn't power up.
if grep -qs 3605 /sys/bus/usb/devices/*/idProduct; then
	for f in $VIOLA_FILES; do
		get "$f" || die "couldn't download $f (are you online?). The extras above are installed."
	done
	chmod 755 /usr/local/sbin/ps5-viola-bt-reset /usr/local/sbin/ps5-viola-bt-revive
	systemctl daemon-reload
	systemctl enable -q ps5-viola-bt-reset.service ps5-viola-bt-revive.service
	udevadm control --reload 2>/dev/null || true
	echo "PS5 Pro Bluetooth: reset/revive services and no-autosuspend rule installed."
fi

# DualSense pairings from PS5 OS: a loader with pairing export writes them to the boot
# partition, and ps5-bt-sync (ps5-linux-patches, pinned) imports them before bluetoothd starts.
if [ "$(sha256sum "$SYNC" 2>/dev/null | cut -d' ' -f1)" = "$SYNC_SHA" ] &&
   systemctl -q is-enabled ps5-bt-sync.service 2>/dev/null; then
	echo "PS5 OS pairing import: already installed."
else
	mkdir -p "$(dirname "$SYNC")"
	curl -fsSL --max-time 60 -o "$SYNC.new" "$SYNC_URL" ||
		{ rm -f "$SYNC.new"; die "couldn't download ps5-bt-sync (are you online?). The extras above are installed."; }
	[ "$(sha256sum "$SYNC.new" | cut -d' ' -f1)" = "$SYNC_SHA" ] ||
		{ rm -f "$SYNC.new"; die "ps5-bt-sync came out wrong (download cut off?). The extras above are installed."; }
	chmod 755 "$SYNC.new"; mv "$SYNC.new" "$SYNC"
	[ -f /etc/ps5-bt-sync.conf ] || {
		printf '# PS5-CachyOS update-extras (no adapter line: uses the only Bluetooth adapter present)\n[sync]\nboot_directory = /boot/efi\nstorage_directory = /var/lib/bluetooth\n' > /etc/ps5-bt-sync.conf
		chmod 600 /etc/ps5-bt-sync.conf
	}
	cat > /etc/systemd/system/ps5-bt-sync.service <<'PS5EOF'
# PS5-CachyOS update-extras: ps5-bt-sync from ps5-linux-patches (bluetooth/)
[Unit]
Description=Import PS5 Bluetooth pairings
After=local-fs.target systemd-modules-load.service
Before=bluetooth.service
ConditionPathExists=/etc/ps5-bt-sync.conf
RequiresMountsFor=/boot/efi /var/lib/bluetooth

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/ps5-bt-sync
TimeoutStartSec=30
UMask=0077
NoNewPrivileges=yes

[Install]
WantedBy=bluetooth.service
PS5EOF
	systemctl daemon-reload
	systemctl enable -q ps5-bt-sync.service
	echo "PS5 OS pairing import installed: controllers paired in PS5 OS work in Linux too"
	echo "  (needs a loader with pairing export, e.g. ps5-linux-loader newer than v2.5)."
fi

# Switch pictures: a full-screen "Gaming Mode" / "Desktop" picture instead of console text
# while switching modes. Hooks go into the image's switch scripts (originals kept as .bak-extras).
if [ -x /usr/bin/python3 ] && python3 -c 'import PIL' 2>/dev/null; then
	for f in $SPLASH_FILES; do
		get "$f" || die "couldn't download $f (are you online?). The extras above are installed."
	done
	chmod 755 /usr/local/bin/ps5-splash
	/usr/local/bin/ps5-splash --build >/dev/null
	hooked=0
	hook /usr/local/bin/ps5-warm-desktop \
		"pkill -9 -u steam -x 'gamescope-wl|gamescope|Xwayland|kwin_wayland_wr|kwin_wayland|plasmashell'" after \
		'[ -x /usr/local/bin/ps5-splash ] && /usr/local/bin/ps5-splash desktop || true' && hooked=$((hooked+1))
	hook /usr/bin/steamos-session-select "pkill -u steam Xwayland || true" after \
		'        [ -x /usr/local/bin/ps5-splash ] && /usr/local/bin/ps5-splash gaming --mark-only || true' && hooked=$((hooked+1))
	hook_tty && hooked=$((hooked+1))
	echo "Switch pictures installed ($hooked of 3 switch scripts hooked)."
else
	echo "Switch pictures: skipped (python-pillow is missing)."
fi
sync

echo
echo "Done. You now have:"
echo "  - Gaming Mode without the Steam update loop, and a performance overlay (Steam menu ->"
echo "    Performance) if the launcher was updated above."
echo "  - Desktop Steam on the same client build as Gaming Mode (restart Steam if it's open)."
echo "  - Faster shader pre-caching (all 16 threads)."
echo "  - Refresh rate in Steam -> Settings -> Display (also live, in Gaming Mode)."
echo "  - HDR in Gaming Mode (quick menu -> Performance) on the PS5 Fat and Pro."
echo "  - 12-bit Colour icon on the desktop."
echo "  - Faster DualSense reconnects, and controllers paired in PS5 OS also work in Linux"
echo "    (with a loader that exports pairings; a device used in both should be paired in PS5 OS)."
echo "  - A picture instead of text while switching between Gaming Mode and the desktop."
echo "If KDE asks whether to trust an icon the first time you click it, choose 'Continue'."
echo "Undo with:"
echo "  curl -fsSL $URL | sudo sh -s -- --rollback"
