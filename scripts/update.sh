#!/bin/sh
# PS5 CachyOS: bring an existing install up to the newest release, no reflash.
#
# Update:   curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update.sh | sh
# Undo:     curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update.sh | sh -s -- --rollback
#
# Run it as your normal user, NOT with sudo (it asks for the password itself).
# It runs, in order:
#   1. update-kernel.sh   newest PS5 kernel + modules + Wi-Fi driver (+ 12-bit colour fix)
#   2. Fixes:            12-bit colour script only on FLAVA3 (PS5 Slim / VERDE got a colour tint)
#   3. update-extras.sh   Gaming Mode refresh rate menu + "12-bit Colour" icon
#                         (only on installs from the 2026-11-10 image or newer; skipped otherwise)
#   4. FreeSync + 1080p 144 Hz boot options (asks first)
#   5. quiet-fan.sh       quieter fan curve + SoC Temp in the panel (asks first, default no)
#   6. Updater:           "Update PS5 CachyOS" icon (runs this script) + a daily check that
#                         shows a notification when a newer kernel is out
# Each step keeps backups, so --rollback undoes all of it.
set -u

R=https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts
BOOT=${PS5_BOOT:-/boot/efi}
CMD="$BOOT/cmdline.txt"
OPTS="hdmi.vrr=1 hdmi.extended_tmds=1"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
# answers come from the keyboard, even when the script itself is piped in
ask() { # ask "question" default(y|n)
	d=$2; printf '%s [%s] ' "$1" "$( [ "$d" = y ] && echo Y/n || echo y/N )"
	read a </dev/tty 2>/dev/null || a=""
	case "${a:-$d}" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}
fetch() { curl -fsSL "$R/$1" || die "couldn't download $1 (are you online?)"; }

DESK=$(xdg-user-dir DESKTOP 2>/dev/null || true); [ -n "$DESK" ] && [ "$DESK" != "$HOME" ] || DESK="$HOME/Desktop"
UBIN="$HOME/.local/bin"; UNIT="$HOME/.config/systemd/user"; APPS="$HOME/.local/share/applications"

install_updater() {
	mkdir -p "$UBIN" "$UNIT" "$APPS" "$DESK"
	cat > "$UBIN/ps5-update" <<PS5EOF
#!/bin/sh
# Runs the newest PS5 CachyOS updater from GitHub.
curl -fsSL $R/update.sh | sh
echo
printf 'Press Enter to close'; read _
PS5EOF
	cat > "$UBIN/ps5-update-check" <<'PS5EOF'
#!/bin/sh
# Shows a notification when a newer PS5 kernel is available (once per version).
new=$(curl -fsSL --max-time 30 https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sed -n 's/^KVER=//p' | head -1)
cur=$(uname -r)
[ -n "$new" ] && [ "$new" != "$cur" ] || exit 0
[ "$(printf '%s\n%s\n' "$new" "$cur" | sort -V | tail -1)" = "$new" ] || exit 0
seen="$HOME/.cache/ps5-update-notified"
[ "$(cat "$seen" 2>/dev/null)" = "$new" ] && exit 0
mkdir -p "$HOME/.cache"
notify-send -a "PS5 CachyOS" -i system-software-update "PS5 CachyOS update available" \
	"Kernel $new is out (you have $cur). Open \"Update PS5 CachyOS\" on the desktop." && echo "$new" > "$seen"
PS5EOF
	chmod 755 "$UBIN/ps5-update" "$UBIN/ps5-update-check"
	for f in "$DESK/ps5-update.desktop" "$APPS/ps5-update.desktop"; do
		cat > "$f" <<PS5EOF
[Desktop Entry]
Type=Application
Name=Update PS5 CachyOS
Comment=Install the newest PS5 kernel, fixes and extras
Exec=konsole -e $UBIN/ps5-update
Icon=system-software-update
Terminal=false
Categories=System;
PS5EOF
		chmod 755 "$f"
	done
	cat > "$UNIT/ps5-update-check.service" <<PS5EOF
[Unit]
Description=Check for a newer PS5 CachyOS kernel
[Service]
Type=oneshot
ExecStart=$UBIN/ps5-update-check
PS5EOF
	cat > "$UNIT/ps5-update-check.timer" <<'PS5EOF'
[Unit]
Description=Daily check for a newer PS5 CachyOS kernel
[Timer]
OnActiveSec=3min
OnUnitActiveSec=1d
Persistent=true
[Install]
WantedBy=timers.target
PS5EOF
	systemctl --user daemon-reload 2>/dev/null
	systemctl --user enable --now ps5-update-check.timer >/dev/null 2>&1 &&
		echo "Added the \"Update PS5 CachyOS\" icon and a daily update check." ||
		echo "Added the \"Update PS5 CachyOS\" icon (the daily check couldn't be switched on)."
}

remove_updater() {
	systemctl --user disable --now ps5-update-check.timer >/dev/null 2>&1
	rm -f "$UNIT/ps5-update-check.service" "$UNIT/ps5-update-check.timer" "$UBIN/ps5-update" "$UBIN/ps5-update-check" \
		"$DESK/ps5-update.desktop" "$APPS/ps5-update.desktop" "$HOME/.cache/ps5-update-notified"
	systemctl --user daemon-reload 2>/dev/null
	echo "Removed the updater icon and the daily check."
}

[ "$(id -u)" != 0 ] || die "run it as your normal user, without sudo (it asks for the password itself)."
grep -q 'console=ttyTitania0' /proc/cmdline || die "this doesn't look like Linux on a PS5. Nothing changed."
command -v curl >/dev/null || die "'curl' is missing. Install it with: sudo pacman -S curl"

if [ "${1:-}" = "--rollback" ]; then
	echo "Undoing the update (password needed)..."
	sudo -v || exit 1
	say "Kernel"
	fetch update-kernel.sh | sudo sh -s -- --rollback
	say "Gaming Mode extras"
	fetch update-extras.sh | sudo sh -s -- --rollback
	[ -f /usr/local/bin/ps5-color-depth.bak-update ] && sudo mv /usr/local/bin/ps5-color-depth.bak-update /usr/local/bin/ps5-color-depth && echo "Colour script restored."
	if [ -f "$CMD.bak-update" ]; then
		say "Boot options"
		sudo cp "$CMD.bak-update" "$CMD" && echo "Boot options restored."
	fi
	if [ -x /usr/local/sbin/ps5-fan-curve ] && ask "Also remove the quiet fan curve?" n; then
		fetch quiet-fan.sh | sh -s -- --remove
	fi
	say "Updater"
	remove_updater
	echo; echo "Done. Restart to boot the previous kernel."
	exit 0
fi

echo "PS5 CachyOS updater: kernel, fixes and extras from the newest release."
echo "Your files, apps and settings are not touched. Password needed:"
sudo -v || exit 1

say "1/6 Kernel"
if ! fetch update-kernel.sh | sudo sh; then
	die "the kernel update failed (see above). Nothing else was changed."
fi

say "2/6 Fixes"
CD=/usr/local/bin/ps5-color-depth
if [ -f "$CD" ]; then
	if fetch files/ps5-color-depth > /tmp/ps5-color-depth.new && ! cmp -s /tmp/ps5-color-depth.new "$CD"; then
		sudo cp "$CD" "$CD.bak-update" && sudo install -m 755 /tmp/ps5-color-depth.new "$CD" &&
			echo "Colour script updated: 12-bit 4:2:2 only on FLAVA3 (fixes the colour tint on PS5 Slim)."
	else
		echo "Colour script already up to date."
	fi
	rm -f /tmp/ps5-color-depth.new
else
	echo "Nothing to fix."
fi

say "3/6 Gaming Mode extras"
if ! fetch update-extras.sh | sudo sh; then
	echo "Skipped: this install doesn't have the Gaming Mode these extras need (it's fine)."
fi

say "4/6 FreeSync and 1080p 144 Hz"
if grep -q 'hdmi.vrr=1' "$CMD" 2>/dev/null; then
	echo "Already on."
elif [ ! -f "$CMD" ]; then
	echo "Skipped: $CMD not found."
elif ask "Turn on FreeSync (VRR) and 1080p 144 Hz? Safe to leave on; needs a restart." y; then
	sudo cp "$CMD" "$CMD.bak-update" &&
		sudo sed -i "1s/[[:space:]]*\$/ $OPTS/" "$CMD" &&
		echo "Added to $CMD (old one kept as cmdline.txt.bak-update)."
else
	echo "Left off. You can run this updater again later."
fi

say "5/6 Quiet fan curve (optional)"
if [ -x /usr/local/sbin/ps5-fan-curve ]; then
	echo "Already installed."
elif ask "Install the quieter fan curve? The console runs warmer in games; watch temps on stock paste." n; then
	fetch quiet-fan.sh | sh
else
	echo "Skipped (kernel default curve stays)."
fi

say "6/6 Updater"
install_updater

echo
echo "All done. Restart the PS5 Linux to use the new kernel (if it changed)."
echo "Next time, just open \"Update PS5 CachyOS\" on the desktop."
echo "To undo:  curl -fsSL $R/update.sh | sh -s -- --rollback"
