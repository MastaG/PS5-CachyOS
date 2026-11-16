#!/bin/sh
# PS5 CachyOS: bring an existing install up to the newest release, no reflash.
#
# Update:   curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update.sh | sh
# Undo:     curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update.sh | sh -s -- --rollback
#
# Run it as your normal user, NOT with sudo (it asks for the password itself).
# It runs, in order:
#   1. update-kernel.sh   newest PS5 kernel + modules + Wi-Fi driver (+ 12-bit colour fix)
#   2. update-extras.sh   Gaming Mode refresh rate menu + "12-bit Colour" icon
#                         (only on installs from the 2026-11-10 image or newer; skipped otherwise)
#   3. FreeSync + 1080p 144 Hz boot options (asks first)
#   4. quiet-fan.sh       quieter fan curve + SoC Temp in the panel (asks first, default no)
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
	if [ -f "$CMD.bak-update" ]; then
		say "Boot options"
		sudo cp "$CMD.bak-update" "$CMD" && echo "Boot options restored."
	fi
	if [ -x /usr/local/sbin/ps5-fan-curve ] && ask "Also remove the quiet fan curve?" n; then
		fetch quiet-fan.sh | sh -s -- --remove
	fi
	echo; echo "Done. Restart to boot the previous kernel."
	exit 0
fi

echo "PS5 CachyOS updater: kernel, fixes and extras from the newest release."
echo "Your files, apps and settings are not touched. Password needed:"
sudo -v || exit 1

say "1/4 Kernel"
if ! fetch update-kernel.sh | sudo sh; then
	die "the kernel update failed (see above). Nothing else was changed."
fi

say "2/4 Gaming Mode extras"
if ! fetch update-extras.sh | sudo sh; then
	echo "Skipped: this install doesn't have the Gaming Mode these extras need (it's fine)."
fi

say "3/4 FreeSync and 1080p 144 Hz"
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

say "4/4 Quiet fan curve (optional)"
if [ -x /usr/local/sbin/ps5-fan-curve ]; then
	echo "Already installed."
elif ask "Install the quieter fan curve? The console runs warmer in games; watch temps on stock paste." n; then
	fetch quiet-fan.sh | sh
else
	echo "Skipped (kernel default curve stays)."
fi

echo
echo "All done. Restart the PS5 Linux to use the new kernel."
echo "To undo:  curl -fsSL $R/update.sh | sh -s -- --rollback"
