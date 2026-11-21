#!/bin/bash
# Container side of image/build-image.sh (privileged Arch container). Not meant to be run by hand.
#   /w/base.img     abrocoma's PS5-CachyOS image (ext4 root p1, FAT "boot" p2)
#   /w/kernel.tar.zst  ps5-kernel-<ver>.tar.zst (VERSION, boot/bzImage, usr/lib/modules/<ver>)
#   /w/out.img      the new image (written here)
#   /repo           this repository (image/overlay, scripts/)
set -Eeuo pipefail
trap 'echo "ERROR line $LINENO: $BASH_COMMAND" >&2' ERR

IMG_MB=${IMG_MB:-12000}
OPTS=noatime,compress=zstd   # in the image's fstab: what the PS5 writes later is compressed
# While building, files go in uncompressed: the image is xz-compressed as a whole, and xz cannot shrink
# zstd data (GitHub release files must stay under 2 GiB).
BUILD_OPTS=noatime
SUBVOLS="@ @home @root @srv @cache @log @tmp"
N=/n

pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman -Syu --noconfirm --needed btrfs-progs dosfstools parted arch-install-scripts rsync zstd e2fsprogs python >/dev/null

# Loop devices: a container only has the /dev/loopN nodes that existed when it started.
for i in $(seq 0 63); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
loop() { losetup -f --show -o $(($2 * 512)) --sizelimit $(($3 * 512)) "$1"; } # loop <file> <start> <sectors>
part() { sfdisk -d "$1" | awk -v n="$2" -F'[=, ]+' '$1 ~ n"$" { for (i = 1; i <= NF; i++) { if ($i == "start") s = $(i + 1); if ($i == "size") z = $(i + 1) } print s, z }'; }
LOOPS=()
cleanup() {
	umount -R "$N" /src /srcboot 2>/dev/null || true
	for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null || true; done
}
trap cleanup EXIT

echo "== Base image"
read -r rs rz < <(part /w/base.img 1); read -r bs bz < <(part /w/base.img 2)
L=$(loop /w/base.img "$rs" "$rz"); LOOPS+=("$L"); mkdir -p /src; mount -o ro "$L" /src
L=$(loop /w/base.img "$bs" "$bz"); LOOPS+=("$L"); mkdir -p /srcboot; mount -o ro "$L" /srcboot
grep -q '^LABEL=cachyos ' /src/etc/fstab || { echo "unexpected base fstab"; cat /src/etc/fstab; exit 1; }

echo "== New image: GPT, boot (FAT, p2) + root (btrfs, p1), same places as the base image"
rm -f /w/out.img; truncate -s "${IMG_MB}M" /w/out.img
# Same table as the base image: p1 = root (from sector 1024000), p2 = boot (2048-1023999).
sfdisk -q /w/out.img <<EOT
label: gpt
start=1024000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="primary"
start=2048, size=1021952, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="primary"
EOT
read -r rs rz < <(part /w/out.img 1); read -r bs bz < <(part /w/out.img 2)
RL=$(loop /w/out.img "$rs" "$rz"); LOOPS+=("$RL")
BL=$(loop /w/out.img "$bs" "$bz"); LOOPS+=("$BL")
mkfs.vfat -n boot -F32 "$BL" >/dev/null
mkfs.btrfs -q -L cachyos "$RL"

mkdir -p "$N"; mount -o "$BUILD_OPTS" "$RL" "$N"
for s in $SUBVOLS; do btrfs -q subvolume create "$N/$s"; done
umount "$N"
mount -o "$BUILD_OPTS,subvol=@" "$RL" "$N"
for m in home:@home root:@root srv:@srv var/cache:@cache var/log:@log var/tmp:@tmp; do
	mkdir -p "$N/${m%%:*}"; mount -o "$BUILD_OPTS,subvol=${m##*:}" "$RL" "$N/${m%%:*}"
done
btrfs -q subvolume create "$N/var/swap"; chattr +C "$N/var/swap"
mkdir -p "$N/boot/efi"; mount "$BL" "$N/boot/efi"

echo "== Copying the base system"
rsync -aHAX --numeric-ids --filter="-x security.selinux" /src/ "$N/"
cp -a /srcboot/. "$N/boot/efi/"

echo "== fstab, cmdline.txt, pacman.conf, initrd modules"
{
	echo "# PS5-CachyOS btrfs image (layout as on a CachyOS install: @ @home @root @srv @cache @log @tmp)"
	for m in /:@ /home:@home /root:@root /srv:@srv /var/cache:@cache /var/log:@log /var/tmp:@tmp; do
		printf 'LABEL=cachyos %-11s btrfs subvol=/%s,defaults,%s 0 0\n' "${m%%:*}" "${m##*:}" "$OPTS"
	done
	grep -E '[[:space:]]/boot/efi[[:space:]]' /src/etc/fstab
} > "$N/etc/fstab"
cat "$N/etc/fstab"

# Same line as the base image, plus btrfs root, the GFX1013 compute params (as on the BC-250) and zswap.
cmd=$(tr -d '\n' < /srcboot/cmdline.txt)
cmd="${cmd/ rw / rw rootflags=subvol=@ }"
for p in ttm.pages_limit=3670016 amdgpu.sched_policy=2 amdgpu.vm_update_mode=0 amdgpu.cwsr_enable=0 \
	amdgpu.bc250_gfx_eop_events=2 zswap.enabled=1 zswap.max_pool_percent=25 zswap.compressor=zstd; do
	case " $cmd " in *" ${p%%=*}="*) ;; *) cmd="$cmd $p" ;; esac
done
printf '%s\n' "$cmd" > "$N/boot/efi/cmdline.txt"; cat "$N/boot/efi/cmdline.txt"

python3 - "$N/etc/pacman.conf" <<'EOF'
import sys
p = sys.argv[1]; t = open(p).read()
first = ("# BC-250 / GFX1013 Mesa (znver2), Proton builds: above the Arch and CachyOS repos so its Mesa wins.\n"
         "[bc250-cachyos]\nSigLevel = Optional TrustAll\n"
         "Server = https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo\n\n")
last = ("\n# Emulators (nothing installed by default): sudo pacman -S lichii-bc250 kytyps5-native-git\n"
        "[bc250-emulators]\nSigLevel = Optional TrustAll\n"
        "Server = https://github.com/MastaG/bc250-emulators/releases/download/repo\n")
assert "[bc250-cachyos]" not in t
i = t.index("\n[core]") + 1
open(p, "w").write(t[:i] + first + t[i:].rstrip("\n") + "\n" + last)
EOF
grep -n '^\[' "$N/etc/pacman.conf"
mkdir -p "$N/etc/mkinitcpio.conf.d"
echo 'MODULES+=(btrfs)' > "$N/etc/mkinitcpio.conf.d/btrfs.conf"
printf '# zram is off: swap file + zswap (cmdline.txt), as on the BC-250.\n' > "$N/etc/systemd/zram-generator.conf"

echo "== Overlay"
# --chown: the overlay's owner on the build PC (often uid 1000 = steam on the PS5) must never reach the image.
rsync -rlpt --chown=0:0 /repo/image/overlay/ "$N/"
# Steam runs as a user unit, so KytyPS5 can unload it while a game runs (as on the BC-250).
g="$N/usr/bin/gamescope-session-ps5"
grep -q '^    /usr/bin/steam -gamepadui -steamos3 -steampal$' "$g" || { echo "gamescope-session-ps5 changed upstream"; exit 1; }
sed -i 's|^    /usr/bin/steam -gamepadui -steamos3 -steampal$|    /usr/local/bin/ps5-steam-session|' "$g"
# Every boot starts in Gaming Mode, as on SteamOS / the BC-250 (ps5-boot-session.service copies this to
# ps5-next-session at boot). "Switch to Desktop" still works until the next restart.
su=$(awk -F: '$1 == "steam" { print $3 ":" $4 }' "$N/etc/passwd")
for f in ps5-boot-session ps5-next-session; do
	echo gamescope > "$N/home/steam/.config/$f"; chown "$su" "$N/home/steam/.config/$f"
done
# Updates come from this fork.
for f in "$N/home/steam/.local/bin/ps5-update" "$N/home/steam/.local/bin/ps5-update-check"; do
	[ -f "$f" ] && sed -i 's|abrocoma/PS5-CachyOS|MastaG/PS5-CachyOS|g' "$f"
done
grep -c 'MastaG/PS5-CachyOS' "$N/home/steam/.local/bin/ps5-update" || true

echo "== Kernel"
mkdir -p /k; zstd -dc /w/kernel.tar.zst | tar -xf - -C /k
KVER=$(cat /k/VERSION)
cp -a "/k/usr/lib/modules/$KVER" "$N/usr/lib/modules/"
chown -R 0:0 "$N/usr/lib/modules/$KVER"
# Upstream's kernel is not kept (release files must stay under 2 GiB, and its modules are already
# compressed): the first kernel update keeps the previous kernel as .bak.
for d in "$N"/usr/lib/modules/*; do [ "$(basename "$d")" = "$KVER" ] || rm -rf "$d"; done
rm -f "$N/boot/efi/bzImage.bak" "$N/boot/efi/initrd.img.bak"
cp /k/boot/bzImage "$N/boot/efi/bzImage"

echo "== Packages (chroot)"
arch-chroot "$N" /bin/bash -euo pipefail -c '
	pacman-key --init >/dev/null 2>&1; pacman-key --populate >/dev/null 2>&1 || true
	pacman -Syu --noconfirm
	# GPU compute (KFD /dev/kfd, render nodes) for the steam user, as on the BC-250.
	usermod -aG render steam
	pacman -S --noconfirm --needed btrfs-progs snapper btrfs-assistant compsize git rsync unzip
	pacman -Q mesa vulkan-radeon lib32-vulkan-radeon
	# snapper: one config for / like the BC-250, snapshots before/after each pacman run (snap-pac).
	snapper --no-dbus -c root create-config /
	sed -i -e "s/^TIMELINE_CREATE=.*/TIMELINE_CREATE=\"no\"/" -e "s/^NUMBER_LIMIT=.*/NUMBER_LIMIT=\"50\"/" \
		-e "s/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT=\"15\"/" -e "s/^SPACE_LIMIT=.*/SPACE_LIMIT=\"0.5\"/" \
		-e "s/^FREE_LIMIT=.*/FREE_LIMIT=\"0.2\"/" /etc/snapper/configs/root
	pacman -S --noconfirm --needed snap-pac
	# snap-pac snapshots its own install (no D-Bus here, so only half): ship without snapshots.
	for s in /.snapshots/*/snapshot; do [ -d "$s" ] && btrfs -q subvolume delete "$s"; done
	rm -rf /.snapshots/[0-9]*
	systemctl enable snapper-cleanup.timer ps5-swapfile.service grow-rootfs.service ps5-boot-session.service systemd-timesyncd.service
	systemctl disable ps5boost.service 2>/dev/null || true
	depmod -a '"$KVER"'
	mkinitcpio -k '"$KVER"' -g /boot/efi/initrd.img
	pacman -Scc --noconfirm >/dev/null
'
# The base image starts without a machine ID and without pacman sockets; keep it that way.
: > "$N/etc/machine-id"
rm -f "$N"/etc/pacman.d/gnupg/S.* "$N/var/lib/pacman/db.lck"
# Nothing outside /home may belong to a normal user (uid 1000 is steam on the PS5).
bad=$(find "$N" -xdev \( -path "$N/home" -o -path "$N/proc" -o -path "$N/sys" -o -path "$N/run" -o -path "$N/tmp" \) -prune -o -uid +999 -uid -60000 -print)
for d in "$N/var/cache" "$N/var/log" "$N/var/tmp" "$N/srv" "$N/root"; do bad+=$(find "$d" -xdev -uid +999 -uid -60000 -print); done
[ -z "$bad" ] || { echo "files owned by a normal user:"; echo "$bad" | head -20; exit 1; }
btrfs subvolume list "$N" | sed 's/^/  /'
ls -la "$N/boot/efi"; df -h "$N" | tail -1
# Free blocks still hold what the build deleted (old packages, the pacman cache): discard them so the
# image file gets holes there, which compress to nothing (GitHub release files must stay under 2 GiB).
fstrim -v "$N"
fstrim -v "$N/boot/efi" || true
echo "KVER=$KVER" > /w/out.env
chown "$(stat -c %u:%g /w)" /w/out.img /w/out.env
