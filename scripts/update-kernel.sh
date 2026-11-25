#!/bin/sh
# PS5 CachyOS: install the newest kernel from the PS5-CachyOS repo (kernel/) without reflashing.
#
# Update:    curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sudo sh
# Roll back: curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sudo sh -s -- --rollback
# Headers:   curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sudo sh -s -- --headers
#            (kernel headers for DKMS drivers such as xone; installed again with every later kernel update)
#
# Installs the kernel (bzImage), its modules (incl. the Wi-Fi driver) and builds a
# new initrd. The current kernel + initrd are kept as bzImage.bak / initrd.img.bak
# so --rollback can put them back. On older images it also updates the 12-bit
# colour script for kernel 7.3 (old one kept as .bak). Your files, apps, settings
# and cmdline.txt are not touched.
set -eu

KVER=7.3.5-pc8fe3
KDATE="25 Nov 2026"   # release date, shown by the updater
PKG=ps5-kernel-$KVER.tar.zst
URL=${PS5_KERNEL_URL:-https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/kernel}
BOOT=${PS5_BOOT:-/boot/efi}
HDR_PKG=ps5-kernel-headers-$KVER.tar.zst
HDR_URL=${PS5_HEADERS_URL:-https://github.com/abrocoma/PS5-CachyOS/releases/download/image-2026-11-26}   # release that has the headers for $KVER
# Headers: asked for, or installed before (then every kernel update brings new ones).
WANT_HDR=0
case " $* " in *" --headers "*) WANT_HDR=1 ;; esac
ls -d /usr/src/linux-headers-*-p* >/dev/null 2>&1 && WANT_HDR=1

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo (see the top of this script)."
grep -q 'console=ttyTitania0' /proc/cmdline || die "this doesn't look like Linux on a PS5. Nothing changed."
# With two PS5 Linux drives plugged in, /boot/efi can be the OTHER drive's boot partition
# (both are labelled "boot"). Never write the kernel to another drive.
# OK when the boot partition is on the same drive as /, or when root= in its cmdline.txt
# names exactly one partition and that is this system's / (USB boot + M.2 root install).
boot_root_ok() {
	r=$(tr ' ' '\n' < "$BOOT/cmdline.txt" 2>/dev/null | sed -n 's/^root=//p' | tail -1)
	case "$r" in
		LABEL=*|UUID=*|PARTUUID=*|PARTLABEL=*) devs=$(blkid -c /dev/null -o device -t "$r" 2>/dev/null || true) ;;
		/dev/*) devs=$r ;;
		*) return 1 ;;
	esac
	[ "$(printf '%s\n' "$devs" | grep -c .)" = 1 ] || return 1
	[ "$(readlink -f "$devs")" = "$(readlink -f "$rsrc")" ]
}
if [ -z "${PS5_BOOT:-}" ]; then
	rsrc=$(findmnt -no SOURCE / | sed 's/\[.*//')
	rdisk=$(lsblk -no PKNAME "$rsrc" 2>/dev/null || true)
	bdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE "$BOOT")" 2>/dev/null || true)
	if ! { [ -n "$rdisk" ] && [ "$rdisk" = "$bdisk" ]; } && ! boot_root_ok; then
		die "$BOOT is on another drive ($bdisk) than this system (${rdisk:-?}), and its cmdline.txt doesn't point to this system. Unplug the other PS5 Linux drive and restart, then run this again. If $BOOT really is this system's boot partition, run with PS5_BOOT=$BOOT. Nothing changed."
	fi
fi

# PS5 Pro (issue #5): on the first boot, ps5-stage-gpu-firmware ran the old
# zz-update-boot hook, which renamed bzImage + initrd.img to .old and then failed,
# so the PS5 had no kernel to boot. Put the .old files back.
for f in bzImage initrd.img; do
	if [ ! -f "$BOOT/$f" ] && [ -s "$BOOT/$f.old" ]; then
		cp "$BOOT/$f.old" "$BOOT/$f.new" && sync && mv "$BOOT/$f.new" "$BOOT/$f" && sync ||
			die "couldn't restore $BOOT/$f from $f.old."
		echo "Restored $BOOT/$f from $f.old (it was lost by a failed PS5 Pro GPU firmware update)."
	fi
done
[ -f "$BOOT/bzImage" ] && [ -f "$BOOT/initrd.img" ] || die "no $BOOT/bzImage + initrd.img found (boot partition not mounted?). Nothing changed."

# Replace the old zz-update-boot hook with the safe one (see scripts/files/zz-update-boot).
# Only on installs that have the hook; the old one is kept outside postinst.d.
HOOK=/etc/kernel/postinst.d/zz-update-boot
FILES=${PS5_FILES_URL:-https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/files}
if [ -f "$HOOK" ] && ! grep -q 'Safe by design' "$HOOK"; then
	if curl -fsSL --max-time 30 -o "$HOOK.new" "$FILES/zz-update-boot" && grep -q 'Safe by design' "$HOOK.new"; then
		cp "$HOOK" /etc/kernel/zz-update-boot.bak
		chmod 755 "$HOOK.new"; mv -f "$HOOK.new" "$HOOK"
		echo "Boot hook updated: it can no longer leave the boot partition without a kernel (old one kept as /etc/kernel/zz-update-boot.bak)."
	else
		rm -f "$HOOK.new"
		echo "Note: couldn't download the new boot hook; run this again later (PS5 Pro needs it)."
	fi
fi

if [ "${1:-}" = "--rollback" ]; then
	[ -s "$BOOT/bzImage.bak" ] && [ -s "$BOOT/initrd.img.bak" ] || die "no (complete) backup kernel found in $BOOT."
	for f in bzImage initrd.img; do
		mv "$BOOT/$f" "$BOOT/$f.tmp"; mv "$BOOT/$f.bak" "$BOOT/$f"; mv "$BOOT/$f.tmp" "$BOOT/$f.bak"
	done
	sync
	echo "Rolled back: the previous kernel is active again (the newer one is now the .bak)."
	echo "Restart the PS5 and boot Linux as usual."
	exit 0
fi

# Kernel headers for $KVER: /usr/src/linux-headers-$KVER, linked as /usr/lib/modules/$KVER/build,
# then DKMS builds its drivers for $KVER. Never fatal: the kernel itself works without them.
install_headers() {
	command -v zstd >/dev/null || { echo "Headers skipped: 'zstd' is missing (sudo pacman -S zstd)."; return 0; }
	h=$(mktemp -d /var/tmp/ps5-headers.XXXXXX)
	echo "Downloading kernel headers $KVER..."
	if curl -fL --progress-bar -o "$h/$HDR_PKG" "$HDR_URL/$HDR_PKG" &&
	   curl -fsSL -o "$h/$HDR_PKG.sha256" "$HDR_URL/$HDR_PKG.sha256" &&
	   (cd "$h" && sha256sum -c --quiet "$HDR_PKG.sha256"); then
		rm -rf "/usr/src/linux-headers-$KVER"
		zstd -dc "$h/$HDR_PKG" | tar -xf - -C /
		ln -sfn "/usr/src/linux-headers-$KVER" "/usr/lib/modules/$KVER/build"
		echo "Kernel headers installed (/usr/lib/modules/$KVER/build): DKMS drivers can be built for this kernel."
		if command -v dkms >/dev/null; then
			echo "Building DKMS drivers for $KVER..."
			dkms autoinstall -k "$KVER" || echo "Note: a DKMS driver didn't build for $KVER (see above); the kernel works anyway."
		fi
	else
		echo "Note: couldn't download the kernel headers for $KVER; run this again later with --headers."
	fi
	rm -rf "$h"
}

FORCE=0; case " $* " in *" --force "*) FORCE=1 ;; esac
if [ "$(uname -r)" = "$KVER" ] && [ $FORCE = 0 ]; then
	echo "You're already on the newest kernel ($KVER)."
	if [ $WANT_HDR = 1 ] && { case " $* " in *" --headers "*) true ;; *) [ ! -e "/usr/lib/modules/$KVER/build" ] ;; esac; }; then
		install_headers
	else
		echo "Nothing to do."
	fi
	exit 0
fi

for c in curl tar zstd sha256sum depmod mkinitcpio; do
	command -v $c >/dev/null || die "'$c' is missing. Install it with: sudo pacman -S $c"
done

# Room on the boot partition: new kernel + initrd, plus the backups.
need=$(( $(du -k "$BOOT/bzImage" | cut -f1) + $(du -k "$BOOT/initrd.img" | cut -f1) + 80000 ))
free=$(df -k --output=avail "$BOOT" | tail -1)
[ "$free" -gt "$need" ] || die "not enough free space on $BOOT (${free} KB free, ~${need} KB needed)."

T=$(mktemp -d /var/tmp/ps5-kernel.XXXXXX)
trap 'rm -rf "$T"' EXIT

echo "Downloading kernel $KVER..."
curl -fL --progress-bar -o "$T/$PKG" "$URL/$PKG"
curl -fsSL -o "$T/$PKG.sha256" "$URL/$PKG.sha256"
(cd "$T" && sha256sum -c --quiet "$PKG.sha256") || die "download is corrupt (checksum mismatch). Nothing changed."

echo "Unpacking..."
mkdir "$T/x"
zstd -dc "$T/$PKG" | tar -xf - -C "$T/x"
[ "$(cat "$T/x/VERSION")" = "$KVER" ] || die "package version mismatch. Nothing changed."

echo "Installing modules..."
rm -rf "/usr/lib/modules/$KVER.new"
cp -a "$T/x/usr/lib/modules/$KVER" "/usr/lib/modules/$KVER.new"
for l in build source; do  # keep kernel-header links if the user has them
	if [ -L "/usr/lib/modules/$KVER/$l" ]; then cp -a "/usr/lib/modules/$KVER/$l" "/usr/lib/modules/$KVER.new/"; fi
done
rm -rf "/usr/lib/modules/$KVER"
mv "/usr/lib/modules/$KVER.new" "/usr/lib/modules/$KVER"
depmod -a "$KVER"
[ $WANT_HDR = 1 ] && install_headers

echo "Building initrd (takes a minute)..."
mkinitcpio -k "$KVER" -g "$T/initrd.img" >"$T/mkinitcpio.log" 2>&1 || {
	tail -20 "$T/mkinitcpio.log" >&2
	die "building the initrd failed. Your boot files were NOT changed; the current kernel still boots."
}

# The 12-bit colour script: older versions only knew the kernel 7.2 setting
# name, and forced 4:2:2 on every console (tints PS5 Slim / VERDE). The new one
# handles both names and only touches FLAVA3.
CD=/usr/local/bin/ps5-color-depth
if [ -f "$CD" ] && ! grep -q 'HDMI IC Type' "$CD"; then
	echo "Updating the 12-bit colour script (old one kept as .bak)..."
	cp "$CD" "$CD.bak"
	cat > "$CD" <<'EOF'
#!/bin/sh
# 12-bit 4:2:2 output to the PS5 HDMI bridge, FLAVA3 only (PS5 Fat).
# VERDE (PS5 Slim) only supports 8-bit RGB: forcing 4:2:2 there gives a
# yellow/red tint, so other chips keep the kernel's default output.
# Kernel 7.3 renamed force_yuv422_output (1 = on) to force_yuv_pixel_format (2 = YCbCr 4:2:2).
ic=$(dmesg 2>/dev/null | sed -n 's/.*HDMI IC Type \[\([A-Za-z0-9]*\)\].*/\1/p' | head -1)
if [ "$ic" != FLAVA3 ]; then
    echo "HDMI chip ${ic:-unknown}: keeping the default 8-bit RGB output"
    exit 0
fi
d=/sys/kernel/debug/dri/0/DP-1
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
for i in $(seq 60); do [ -e "$d/max_bpc" ] && break; sleep 0.5; done
echo c > "$d/max_bpc"
if [ -e "$d/force_yuv_pixel_format" ]; then
    echo 2 > "$d/force_yuv_pixel_format"
else
    echo 1 > "$d/force_yuv422_output"
fi
EOF
	chmod 755 "$CD"
fi

# Wi-Fi driver 6e87c85+: follow the router's country (driver default ignores it).
MP=/etc/modprobe.d/ps5-iw620.conf
if [ -f "$MP" ] && grep -q '^options moal' "$MP" && ! grep -q 'country_ie_ignore' "$MP"; then
	cp "$MP" "$MP.bak"
	sed -i '/^options moal/ s/$/ country_ie_ignore=0 beacon_hints=0/' "$MP"
	echo "Wi-Fi: now follows your router's country setting (old config kept as $MP.bak)."
fi

echo "Swapping boot files (old ones kept as .bak)..."
cp "$BOOT/bzImage" "$BOOT/bzImage.bak"
cp "$BOOT/initrd.img" "$BOOT/initrd.img.bak"
cp "$T/x/boot/bzImage" "$BOOT/bzImage.new"
cp "$T/initrd.img" "$BOOT/initrd.img.new"
sync
mv "$BOOT/bzImage.new" "$BOOT/bzImage"
mv "$BOOT/initrd.img.new" "$BOOT/initrd.img"
sync

echo
echo "Done: kernel $KVER installed. Restart the PS5 and boot Linux as usual."
echo "After the restart, 'uname -r' should say $KVER."
echo "If anything is wrong, roll back with:"
echo "  curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sudo sh -s -- --rollback"
if ! grep -q 'hdmi.vrr=1' "$BOOT/cmdline.txt"; then
	echo
	echo "Tip: for FreeSync and 1080p 144 Hz, add ' hdmi.vrr=1 hdmi.extended_tmds=1' to the end of"
	echo "the single line in $BOOT/cmdline.txt (sudo nano $BOOT/cmdline.txt) and restart."
fi
