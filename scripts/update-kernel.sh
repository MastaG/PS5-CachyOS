#!/bin/sh
# PS5 CachyOS: install the newest kernel from the PS5-CachyOS repo (kernel/) without reflashing.
#
# Update:    curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sudo sh
# Roll back: curl -fsSL https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/scripts/update-kernel.sh | sudo sh -s -- --rollback
#
# Installs the kernel (bzImage), its modules (incl. the Wi-Fi driver) and builds a
# new initrd. The current kernel + initrd are kept as bzImage.bak / initrd.img.bak
# so --rollback can put them back. On older images it also updates the 12-bit
# colour script for kernel 7.3 (old one kept as .bak). Your files, apps, settings
# and cmdline.txt are not touched.
set -eu

KVER=7.3.4-pb33e
PKG=ps5-kernel-$KVER.tar.zst
URL=${PS5_KERNEL_URL:-https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/kernel}
BOOT=${PS5_BOOT:-/boot/efi}

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo (see the top of this script)."
grep -q 'console=ttyTitania0' /proc/cmdline || die "this doesn't look like Linux on a PS5. Nothing changed."
[ -f "$BOOT/bzImage" ] && [ -f "$BOOT/initrd.img" ] || die "no $BOOT/bzImage + initrd.img found (boot partition not mounted?). Nothing changed."

if [ "${1:-}" = "--rollback" ]; then
	[ -f "$BOOT/bzImage.bak" ] && [ -f "$BOOT/initrd.img.bak" ] || die "no backup kernel found in $BOOT."
	for f in bzImage initrd.img; do
		mv "$BOOT/$f" "$BOOT/$f.tmp"; mv "$BOOT/$f.bak" "$BOOT/$f"; mv "$BOOT/$f.tmp" "$BOOT/$f.bak"
	done
	sync
	echo "Rolled back: the previous kernel is active again (the newer one is now the .bak)."
	echo "Restart the PS5 and boot Linux as usual."
	exit 0
fi

FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
if [ "$(uname -r)" = "$KVER" ] && [ $FORCE = 0 ]; then
	echo "You're already on the newest kernel ($KVER). Nothing to do."
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
