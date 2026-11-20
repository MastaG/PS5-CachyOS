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

KVER=7.3.4-p1472
PKG=ps5-kernel-$KVER.tar.zst
URL=${PS5_KERNEL_URL:-https://raw.githubusercontent.com/abrocoma/PS5-CachyOS/main/kernel}
BOOT=${PS5_BOOT:-/boot/efi}

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

# PS5 Pro: ps5-stage-gpu-firmware (installed with the kernel) puts the Viola GPU
# firmware in the initrd and deploys it with /etc/kernel/postinst.d/zz-update-boot.
# That hook first renames bzImage + initrd.img to .old, then copies
# /boot/vmlinuz-<version> + /boot/initrd.img-<version>. Kernels from this repo were
# only installed to $BOOT, so the copy failed and left $BOOT without a kernel.
# Put the renamed files back if that happened.
if [ -s "$BOOT/bzImage.old" ] && [ -s "$BOOT/initrd.img.old" ]; then
	for f in bzImage initrd.img; do
		if [ ! -e "$BOOT/$f" ]; then
			cp "$BOOT/$f.old" "$BOOT/$f.new"; sync; mv "$BOOT/$f.new" "$BOOT/$f"
			echo "Restored $BOOT/$f from $f.old (a failed PS5 Pro GPU firmware deploy had moved it)."
		fi
	done
	sync
fi
[ -f "$BOOT/bzImage" ] && [ -f "$BOOT/initrd.img" ] || die "no $BOOT/bzImage + initrd.img found (boot partition not mounted?). Nothing changed."

# Version of a bzImage, from its setup header (what 'file' shows).
bz_version() {
	o=$(od -An -tu2 -j526 -N2 "$1" 2>/dev/null | tr -d ' ')
	[ -n "$o" ] || return 0
	dd if="$1" bs=1 skip=$((o + 512)) count=200 2>/dev/null | tr '\0' '\n' | head -1 | cut -d' ' -f1
}
# Keep /boot/vmlinuz-<version> (+ initrd) next to the boot partition's kernel, so
# zz-update-boot finds them when ps5-stage-gpu-firmware runs on a PS5 Pro.
# keep_boot_copy kernel [initrd]: the initrd is copied when given, or when /boot has none.
keep_boot_copy() {
	v=$(bz_version "$1")
	[ -n "$v" ] && [ -d "/usr/lib/modules/$v" ] || return 0
	if ! cmp -s "$1" "/boot/vmlinuz-$v"; then
		install -m644 "$1" "/boot/vmlinuz-$v.new"; mv -f "/boot/vmlinuz-$v.new" "/boot/vmlinuz-$v"
	fi
	if [ -n "${2:-}" ] && { [ "${3:-}" = always ] || [ ! -f "/boot/initrd.img-$v" ]; }; then
		install -m600 "$2" "/boot/initrd.img-$v.new"; mv -f "/boot/initrd.img-$v.new" "/boot/initrd.img-$v"
	fi
}

if [ "${1:-}" = "--rollback" ]; then
	[ -s "$BOOT/bzImage.bak" ] && [ -s "$BOOT/initrd.img.bak" ] || die "no (complete) backup kernel found in $BOOT."
	for f in bzImage initrd.img; do
		mv "$BOOT/$f" "$BOOT/$f.tmp"; mv "$BOOT/$f.bak" "$BOOT/$f"; mv "$BOOT/$f.tmp" "$BOOT/$f.bak"
	done
	sync
	keep_boot_copy "$BOOT/bzImage" "$BOOT/initrd.img"
	echo "Rolled back: the previous kernel is active again (the newer one is now the .bak)."
	echo "Restart the PS5 and boot Linux as usual."
	exit 0
fi

FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
if [ "$(uname -r)" = "$KVER" ] && [ $FORCE = 0 ]; then
	keep_boot_copy "$BOOT/bzImage" "$BOOT/initrd.img"
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
keep_boot_copy "$BOOT/bzImage" "$BOOT/initrd.img" always

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
