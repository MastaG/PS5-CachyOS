#!/bin/bash
# Builds the btrfs PS5-CachyOS image on a Linux PC with Docker (or Podman as docker):
# abrocoma's PS5-CachyOS image, moved onto btrfs with a CachyOS subvolume layout, plus this fork's
# kernel, Steam/KytyPS5 session handling, swap/zswap, fan curve, repos and helper scripts.
#
#   image/build-image.sh [--base <abrocoma .img or .img.xz>] [--kernel <ps5-kernel-*.tar.zst>]
#
# Defaults: the base image of BASE_TAG (downloaded), the kernel in kernel/. Output in out/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE_TAG=${BASE_TAG:-image-2026-11-20}
BASE_NAME=${BASE_NAME:-ps5-cachyos-7.3.5-pc8fe.img.xz}
WORK=${WORK:-$ROOT/work}
OUT=${OUT:-$ROOT/out}
BASE= KERNEL=
while [ $# -gt 0 ]; do
	case $1 in
	--base) BASE=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	*) echo "usage: $0 [--base img] [--kernel tar.zst]"; exit 2 ;;
	esac
done
mkdir -p "$WORK" "$OUT"

if [ -z "$BASE" ]; then
	BASE=$WORK/$BASE_NAME
	if [ ! -s "$BASE" ]; then
		curl -fL -o "$BASE" "https://github.com/abrocoma/PS5-CachyOS/releases/download/$BASE_TAG/$BASE_NAME"
		curl -fsSL -o "$BASE.sha256" "https://github.com/abrocoma/PS5-CachyOS/releases/download/$BASE_TAG/$BASE_NAME.sha256"
		(cd "$WORK" && sha256sum -c "$(basename "$BASE").sha256")
	fi
fi
case $BASE in
*.xz)
	raw=$WORK/$(basename "${BASE%.xz}")
	[ -s "$raw" ] || xz -dkcT0 "$BASE" > "$raw"
	BASE=$raw
	;;
esac
[ -n "$KERNEL" ] || KERNEL=$(ls "$ROOT"/kernel/ps5-kernel-*.tar.zst | head -1)
echo "base:   $BASE"
echo "kernel: $KERNEL"

docker run --rm --privileged --memory=20g \
	-v "$ROOT:/repo:ro" -v "$WORK:/w" -v "$(realpath "$BASE"):/w/base.img:ro" -v "$(realpath "$KERNEL"):/w/kernel.tar.zst:ro" \
	archlinux:base-devel bash /repo/image/build-inside.sh

. "$WORK/out.env"
name=ps5-cachyos-$KVER-btrfs-$(date +%Y%m%d).img
mv "$WORK/out.img" "$OUT/$name"
echo "Compressing..."
xz -T0 -9e -c "$OUT/$name" > "$OUT/$name.xz" && rm "$OUT/$name"
(cd "$OUT" && sha256sum "$name.xz" > "$name.xz.sha256" && ls -la "$name.xz")
