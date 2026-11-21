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
#   3. update-extras.sh   Gaming Mode launcher (refresh rate in Steam, HDR on PS5 Fat/Pro, no Steam
#                         update loop, performance overlay), desktop Steam -steamos3 override,
#                         16-thread shader pre-caching, "12-bit Colour" icon
#   4. FreeSync + 1080p 144 Hz boot options (asks first)
#   5. quiet-fan.sh       quieter fan curve + SoC Temp in the panel (asks first, default no)
#   6. Updater:           "Update PS5 CachyOS" icon (runs this script) + a daily check that
#                         shows a notification when a newer kernel is out
#   7. System packages:   pacman -Syu + flatpak update + lists new .pacnew files (asks first)
# Steps 1-6 keep backups, so --rollback undoes them (package updates in step 7 can't be undone).
set -u

R=https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts
BOOT=${PS5_BOOT:-/boot/efi}
CMD="$BOOT/cmdline.txt"
OPTS="hdmi.vrr=1 hdmi.extended_tmds=1"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

# One line per step; everything the steps print goes to the log.
LOG="$HOME/.cache/ps5-update.log"
RULE='──────────────────────────────────────────────────────────────'
if [ -t 1 ]; then
	GRN=$(printf '\033[32m'); RED=$(printf '\033[31m'); YEL=$(printf '\033[33m')
	BLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); OFF=$(printf '\033[0m'); CL=$(printf '\r\033[K')
	BLU=$(printf '\033[38;5;33m')
else
	GRN= RED= YEL= BLD= DIM= OFF= CL= BLU=
fi
line() { printf '%s  %s%s%s %-20s %s' "$CL" "$1" "$2" "$OFF" "$3" "$4"; }
busy() { line "$DIM" "…" "$1" "$2"; }
ok()   { line "$GRN" "✓" "$1" "$2"; echo; }
bad()  { line "$RED" "✗" "$1" "$2"; echo; }
skip() { line "$DIM" "–" "$1" "$2"; echo; }
# run <step> <command...>: output to the log under a marker for that step
run() { s=$1; shift; printf '\n===== %s =====\n' "$s" >> "$LOG"; "$@" >> "$LOG" 2>&1 </dev/null; }
# what <step> printed (for checks and error output)
out() { awk -v m="===== $1 =====" '$0 == m { b = ""; on = 1; next } /^===== / { on = 0 } on { b = b $0 "\n" } END { printf "%s", b }' "$LOG"; }
# the last lines of a failed step, under its line
why() { out "$1" | grep -v '^[[:space:]]*$' | tail -n 6 | sed "s/^/      $DIM/; s/\$/$OFF/"; }
# The header: title and intro on the left, PS5 logo and this console's info on the right.
# Narrow windows: no logo; very narrow: the info goes under the title.
header() {
	gpu=$(cat /sys/class/drm/card*/device/device 2>/dev/null | head -1)
	ic=$(journalctl -k -b --no-pager 2>/dev/null | sed -n 's/.*HDMI IC Type \[\([A-Za-z0-9]*\)\].*/\1/p' | head -1)
	if [ "$gpu" = 0x13da ]; then model="PS5 Pro"; elif [ "$ic" = VERDE ]; then model="PS5 Slim"; elif [ "$ic" = FLAVA3 ]; then model="PS5 Fat"; else model="PS5"; fi
	[ -n "$ic" ] && model="$model ($ic HDMI)"
	kern=$(uname -r); [ "$kern" = "${new:-}" ] && kern="$kern$kd"
	plasma=$(plasmashell --version 2>/dev/null | sed -n 's/^plasmashell /KDE Plasma /p')
	mem=$(free -h --si 2>/dev/null | awk '/^Mem:/ { print $3 " / " $2 }')
	disk=$(df -h --output=used,size / 2>/dev/null | awk 'NR == 2 { print $1 " / " $2 }')
	up=$(uptime -p 2>/dev/null | sed 's/^up //')
	cols=$( (stty size </dev/tty) 2>/dev/null | awk '{ print $2 }'); [ -n "$cols" ] || cols=80
	# left: plain text + its style; right: logo + info
	set -- \
		"PS5 CachyOS Updater"                  "$BLD" "██████  ███████ ███████" "$BLD$model$OFF" \
		"github.com/abrocoma/PS5-CachyOS"      "$BLU" "██   ██ ██      ██     " "${DIM}Kernel$OFF   $kern" \
		""                                     ""     "██████  ███████ ███████" "${DIM}Desktop$OFF  ${plasma:-KDE Plasma}" \
		"Kernel, fixes, extras, packages."     "$DIM" "██           ██      ██" "${DIM}Memory$OFF   $mem" \
		"Your files and settings stay as"      "$DIM" "██      ███████ ███████" "${DIM}Disk$OFF     $disk" \
		"they are."                            "$DIM" "                       " "${DIM}Uptime$OFF   $up"
	if [ "$cols" -ge 100 ]; then
		while [ $# -ge 4 ]; do printf '  %s%-34s%s  %s%s%s   %s\n' "$2" "$1" "$OFF" "$BLU" "$3" "$OFF" "$4"; shift 4; done
	else
		# not wide enough for three columns: the logo goes on top
		printf '  %s%s%s\n' "$BLU" "██████  ███████ ███████" "$OFF" "$BLU" "██   ██ ██      ██     " "$OFF" \
			"$BLU" "██████  ███████ ███████" "$OFF" "$BLU" "██           ██      ██" "$OFF" "$BLU" "██      ███████ ███████" "$OFF"
		echo
	fi
	if [ "$cols" -ge 100 ]; then
		:
	elif [ "$cols" -ge 74 ]; then
		while [ $# -ge 4 ]; do printf '  %s%-34s%s  %s\n' "$2" "$1" "$OFF" "$4"; shift 4; done
	else
		while [ $# -ge 4 ]; do printf '  %s%s%s\n' "$2" "$1" "$OFF"; shift 4; done
		echo
		printf '  %s\n' "$BLD$model$OFF" "${DIM}Kernel$OFF   $kern" "${DIM}Desktop$OFF  ${plasma:-KDE Plasma}" "${DIM}Memory$OFF   $mem" "${DIM}Disk$OFF     $disk" "${DIM}Uptime$OFF   $up"
	fi
	w=$cols; [ "$w" -gt 100 ] && w=100
	printf '%s%s%s\n\n' "$DIM" "$(printf '%*s' "$((w - 2))" '' | sed 's/ /─/g' | sed 's/^/  /')" "$OFF"
}
# One key from the keyboard (also when this script itself is piped in): enter, esc or the character.
key() {
	old=$(stty -g </dev/tty 2>/dev/null) || { echo none; return; }
	stty -icanon -echo min 1 time 0 </dev/tty
	k=$(dd bs=1 count=1 </dev/tty 2>/dev/null | od -An -c | tr -d ' ')
	# arrow keys etc. send more right after Esc: read and drop it, and don't count it as Esc
	stty min 0 time 1 </dev/tty; more=$(dd bs=16 count=1 </dev/tty 2>/dev/null | od -An -c | tr -d ' ')
	stty "$old" </dev/tty
	case "$k" in '\n'|'\r') echo enter ;; 033) [ -z "$more" ] && echo esc || echo other ;; *) echo "$k" ;; esac
}
ask() { # ask "question" default(y|n, used only without a keyboard)
	printf '%s  %s?%s %s\n\n    %sEnter = continue    Esc = abort%s' "$CL" "$YEL" "$OFF" "$1" "$DIM" "$OFF"
	while :; do
		case $(key) in
		enter|y|Y) a=0; break ;;
		esc|n|N) a=1; break ;;
		none) [ "$2" = y ] && a=0 || a=1; break ;;
		esac
	done
	# remove the question again; the step's result line takes its place
	if [ -n "$CL" ]; then printf '\r\033[K\033[1A\r\033[K\033[1A\r\033[K'; else echo; fi
	return $a
}
# ?t=<time>: skip GitHub's 5-minute cache, so a fix is used right after it's pushed
fetch() { curl -fsSL "$R/$1?t=$(date +%s)" || die "couldn't download $1 (are you online?)"; }

DESK=$(xdg-user-dir DESKTOP 2>/dev/null || true); [ -n "$DESK" ] && [ "$DESK" != "$HOME" ] || DESK="$HOME/Desktop"
UBIN="$HOME/.local/bin"; UNIT="$HOME/.config/systemd/user"; APPS="$HOME/.local/share/applications"

install_updater() {
	mkdir -p "$UBIN" "$UNIT" "$APPS" "$DESK"
	cat > "$UBIN/ps5-update" <<PS5EOF
#!/bin/sh
# Runs the newest PS5 CachyOS updater from GitHub.
curl -fsSL "$R/update.sh?t=\$(date +%s)" | sh
echo
printf "\nPress any key to close"
old=\$(stty -g </dev/tty 2>/dev/null) && stty -icanon -echo min 1 time 0 </dev/tty
dd bs=1 count=1 </dev/tty >/dev/null 2>&1
[ -n "\$old" ] && stty "\$old" </dev/tty
PS5EOF
	cat > "$UBIN/ps5-update-check" <<'PS5EOF'
#!/bin/sh
# Shows a notification when the repo's PS5 kernel differs from the running one (once per version).
# No version ordering: kernel names end in a commit hash (sort -V ranks pb33e above p1472).
new=$(curl -fsSL --max-time 30 https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sed -n 's/^KVER=//p' | head -1)
cur=$(uname -r)
[ -n "$new" ] && [ "$new" != "$cur" ] || exit 0
seen="$HOME/.cache/ps5-update-notified"
[ "$(cat "$seen" 2>/dev/null)" = "$new" ] && exit 0
mkdir -p "$HOME/.cache"
notify-send -a "PS5 CachyOS" -i system-software-update "PS5 CachyOS update available" \
	"Kernel $new is out (you have $cur). Open \"Update PS5 CachyOS\" on the desktop." && echo "$new" > "$seen"
PS5EOF
	chmod 755 "$UBIN/ps5-update" "$UBIN/ps5-update-check"
	# Breeze's update icon, framed tighter so it's as big as the other desktop icons
	mkdir -p "$HOME/.local/share/icons"
	cat > "$HOME/.local/share/icons/ps5-update-circle.svg" <<'PS5EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" id="svg7" version="1.1" viewBox="3 3 18 18" width="24" height="24">
  <defs id="defs3">
    <style type="text/css" id="current-color-scheme">.ColorScheme-Text { color: #fcfcfc; } </style>
  </defs>
  <g transform="translate(1,1)">
    <path id="path842" d="m11 3a8 8 0 0 0-8 8h1a7 7 0 0 1 7-7 7 7 0 0 1 7 7 7 7 0 0 1-7 7 7 7 0 0 1-6.3105469-4h2.3105469v-1h-2.6972656-1.0332032-0.2695312v1 3h1v-2.195312a8 8 0 0 0 7 4.195312 8 8 0 0 0 8-8 8 8 0 0 0-8-8zm0 3-4 4h2v5h4v-5h2l-4-4z" class="ColorScheme-Text" fill="currentColor" stroke-linecap="round" style="paint-order:markers fill stroke"/>
  </g>
</svg>
PS5EOF
	for f in "$DESK/ps5-update.desktop" "$APPS/ps5-update.desktop"; do
		cat > "$f" <<PS5EOF
[Desktop Entry]
Type=Application
Name=Update PS5 CachyOS
Comment=Install the newest PS5 kernel, fixes, extras and system updates
Exec=konsole --hide-menubar --hide-tabbar -p "LocalTabTitleFormat=PS5 CachyOS Updater" -e $UBIN/ps5-update
Icon=$HOME/.local/share/icons/ps5-update-circle.svg
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
		"$DESK/ps5-update.desktop" "$APPS/ps5-update.desktop" "$HOME/.cache/ps5-update-notified" \
		"$HOME/.local/share/icons/ps5-update-circle.svg"
	systemctl --user daemon-reload 2>/dev/null
	echo "Removed the updater icon and the daily check."
}

# Run the kernel script as root. sudo drops environment variables, so pass PS5_BOOT on
# when it's set (e.g. PS5_BOOT=/boot/efi sh update.sh to skip the same-drive check).
kernel_sh() {
	if [ -n "${PS5_BOOT:-}" ]; then sudo env PS5_BOOT="$PS5_BOOT" sh "$@"; else sudo sh "$@"; fi
}

[ "$(id -u)" != 0 ] || die "run it as your normal user, without sudo (it asks for the password itself)."
grep -q 'console=ttyTitania0' /proc/cmdline || die "this doesn't look like Linux on a PS5. Nothing changed."
command -v curl >/dev/null || die "'curl' is missing. Install it with: sudo pacman -S curl"

if [ "${1:-}" = "--rollback" ]; then
	echo "Undoing the update (password needed)..."
	sudo -v || exit 1
	say "Kernel"
	fetch update-kernel.sh | kernel_sh -s -- --rollback
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
	echo "Note: system packages and Flatpak apps updated in step 7/7 cannot be undone."
	echo; echo "Done. Restart to boot the previous kernel."
	exit 0
fi

[ -t 1 ] && printf '\033[H\033[2J'
# newest kernel version and date from the repo (also shown in the header)
ks=$(curl -fsSL --max-time 30 "$R/update-kernel.sh" 2>/dev/null)
new=$(printf '%s\n' "$ks" | sed -n 's/^KVER=//p' | head -1)
kdate=$(printf '%s\n' "$ks" | sed -n 's/^KDATE="\([^"]*\)".*/\1/p' | head -1)
kd=${kdate:+, $kdate}   # ", 20 Nov 2026" when the repo says it
header
sudo -v || exit 1
T0=$(date +%s)
# keep sudo alive through long steps
( while sleep 50; do sudo -n -v 2>/dev/null || exit 0; done ) &
KEEP=$!
trap 'kill $KEEP 2>/dev/null' EXIT
mkdir -p "$HOME/.cache"
echo "PS5 CachyOS update, $(date)" > "$LOG"
echo
RESTART=0

# 1. Kernel
KFAIL=0
if [ -n "$new" ] && [ "$new" != "$(uname -r)" ]; then busy "Kernel" "installing $new (1-3 min)"; else busy "Kernel" "checking"; fi
kernel_step() { fetch update-kernel.sh | kernel_sh; }
if run Kernel kernel_step; then
	if out Kernel | grep -q '^Done: kernel'; then
		ok "Kernel" "updated to $new$kd"; RESTART=1
	elif out Kernel | grep -q 'already on the newest kernel'; then
		if [ "$(uname -r)" = "$new" ]; then ok "Kernel" "up to date ($new$kd)"; else ok "Kernel" "up to date ($(uname -r))"; fi
	else
		ok "Kernel" "done"
	fi
else
	KFAIL=1
	bad "Kernel" "failed, your current kernel stays"; why Kernel
fi

# 2. Fixes
busy "Fixes" "checking"
CD=/usr/local/bin/ps5-color-depth
fixes_step() {
	[ -f "$CD" ] || { echo "no colour script"; return 0; }
	fetch files/ps5-color-depth > /tmp/ps5-color-depth.new || return 1
	if ! cmp -s /tmp/ps5-color-depth.new "$CD"; then
		sudo cp "$CD" "$CD.bak-update" && sudo install -m 755 /tmp/ps5-color-depth.new "$CD" && echo "colour script updated"
	fi
	rm -f /tmp/ps5-color-depth.new
}
if run Fixes fixes_step; then
	if out Fixes | grep -q 'colour script updated'; then ok "Fixes" "colour script updated"; else ok "Fixes" "nothing to fix"; fi
else
	bad "Fixes" "failed"; why Fixes
fi

# 3. Gaming Mode and Steam extras
busy "Gaming Mode extras" "checking"
extras_step() { fetch update-extras.sh | sudo sh; }
if run Extras extras_step; then
	ok "Gaming Mode extras" "up to date"
elif out Extras | grep -q "doesn't have the SteamOS-style Gaming Mode"; then
	skip "Gaming Mode extras" "not used on this install"
else
	bad "Gaming Mode extras" "failed"; why Extras
fi

# 4. FreeSync and 1080p 144 Hz
if grep -q 'hdmi.vrr=1' "$CMD" 2>/dev/null; then
	ok "FreeSync, 144 Hz" "on"
elif [ ! -f "$CMD" ]; then
	skip "FreeSync, 144 Hz" "$CMD not found"
elif ask "Turn on FreeSync (VRR) and 1080p 144 Hz? Safe to leave on." y; then
	if sudo cp "$CMD" "$CMD.bak-update" && sudo sed -i "1s/[[:space:]]*\$/ $OPTS/" "$CMD"; then
		ok "FreeSync, 144 Hz" "turned on"; RESTART=1
	else
		bad "FreeSync, 144 Hz" "couldn't change $CMD"
	fi
else
	skip "FreeSync, 144 Hz" "aborted (stays off)"
fi

# 5. Quiet fan curve (optional)
if [ -x /usr/local/sbin/ps5-fan-curve ]; then
	ok "Quiet fan curve" "on"
elif ask "Install the quieter fan curve? The console runs warmer in games." n; then
	busy "Quiet fan curve" "installing"
	fan_step() { fetch quiet-fan.sh | sh; }
	if run Fan fan_step; then ok "Quiet fan curve" "installed"; else bad "Quiet fan curve" "failed"; why Fan; fi
else
	skip "Quiet fan curve" "aborted (kernel default curve)"
fi

# 6. Updater icon + daily check
if run Updater install_updater; then ok "Updater" "icon and daily check"; else bad "Updater" "failed"; why Updater; fi

# 7. System packages and apps
if ask "Update system packages and apps now? Takes a few minutes." y; then
	busy "System packages" "updating (a few minutes)"
	if run Packages sudo pacman -Syu --noconfirm --needed mangohud lib32-mangohud; then
		n=$(out Packages | sed -n 's/^Packages (\([0-9]*\)).*/\1/p' | head -1)
		if [ -n "$n" ]; then ok "System packages" "$n updated"; else ok "System packages" "up to date"; fi
	else
		bad "System packages" "failed (run 'sudo pacman -Syu' to see why)"; why Packages
	fi
	if command -v flatpak >/dev/null 2>&1; then
		busy "Flatpak apps" "updating"
		if run Flatpak flatpak update -y --noninteractive; then
			if out Flatpak | grep -qi 'nothing to do'; then ok "Flatpak apps" "up to date"; else ok "Flatpak apps" "updated"; fi
		else
			bad "Flatpak apps" "failed"; why Flatpak
		fi
	fi
	pacnew=$(find /etc -name '*.pacnew' -newermt '-1 hour' 2>/dev/null || true)
	if [ -n "$pacnew" ]; then
		printf '\n===== New .pacnew files =====\n%s\n' "$pacnew" >> "$LOG"
		line "$YEL" "!" "Config files" "$(printf '%s\n' "$pacnew" | grep -c .) new .pacnew file(s), listed in the log"; echo
	fi
else
	skip "System packages" "aborted"
fi

# Optional extras, only offered while they're not installed
if ! pacman -Q xone-dkms >/dev/null 2>&1; then
	printf '%s\n  %sOptional%s   Xbox Wireless Adapter driver (USB dongle for Xbox controllers)\n\n    %sx = install    Enter = done%s' "$CL" "$YEL" "$OFF" "$DIM" "$OFF"
	k=$(key)
	if [ -n "$CL" ]; then printf '\r\033[K\033[1A\r\033[K\033[1A\r\033[K\033[1A\r\033[K'; else echo; fi
	case $k in
	x|X)
		busy "Xbox adapter" "installing headers and driver (2-5 min)"
		# headers first, so DKMS builds xone as soon as it's installed
		xbox_step() {
			fetch update-kernel.sh | kernel_sh -s -- --headers &&
				sudo pacman -S --needed --noconfirm gcc make dkms xone-dkms xone-dongle-firmware
		}
		if run Xbox xbox_step && dkms status xone 2>/dev/null | grep -q "$(uname -r).*installed"; then
			ok "Xbox adapter" "driver installed: restart, then pair dongle and controller"; RESTART=1
		else
			bad "Xbox adapter" "failed"; why Xbox
		fi
		;;
	esac
fi

took=$(( $(date +%s) - T0 ))
if [ $took -ge 60 ]; then took="$((took / 60)) min $((took % 60)) s"; else took="$took s"; fi
printf '\n%s%s%s\n' "$DIM" "$RULE" "$OFF"
if [ "$KFAIL" = 1 ]; then
	printf '%sDone, but the kernel step failed.%s Everything else was updated.\n' "$BLD" "$OFF"
	echo "Run the updater again later, or open an issue with the log below."
elif [ "$RESTART" = 1 ]; then
	printf '%s%sAll done.%s Restart PS5 Linux to use the new kernel and settings.\n' "$BLD" "$GRN" "$OFF"
else
	printf '%s%sAll done.%s Everything is up to date.\n' "$BLD" "$GRN" "$OFF"
fi
printf '%sFinished in %s. Details: %s%s\n' "$DIM" "$took" "$LOG" "$OFF"
{ echo; echo "Undo steps 1-6: curl -fsSL $R/update.sh | sh -s -- --rollback"; } >> "$LOG"
