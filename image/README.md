# btrfs image (this fork)

`build-image.sh` turns the PS5-CachyOS image of [abrocoma/PS5-CachyOS](https://github.com/abrocoma/PS5-CachyOS)
into this fork's image. It doesn't rebuild the system: it copies it onto btrfs and adds the changes below.
Tested on a PS5 Pro (firmware 11.60). Every Pro-only part checks the model and does nothing on other
models, but this image has not been run on a launch or Slim PS5.

## What's different from the upstream image

| | |
|---|---|
| **File system** | btrfs, zstd compression, subvolumes as on a CachyOS install: `@` `/`, `@home`, `@root`, `@srv`, `@cache` `/var/cache`, `@log` `/var/log`, `@tmp` `/var/tmp`; nested `@/.snapshots` and `@/var/swap`. `cmdline.txt` has `rootflags=subvol=@`. |
| **Snapshots** | snapper (config `root`, no timeline, up to 50 numbered snapshots), snap-pac (snapshot before and after every pacman run), btrfs-assistant. The PS5 loader has no boot menu: restore a snapshot from the running system (btrfs-assistant or `snapper rollback`). |
| **Kernel** | `7.3.5-pc8fe-bc1`: upstream's 7.3.5-pc8fe plus the GFX1013 compute/KFD fixes of linux-cachyos-bc250 (`patches/0008`-`0016`, source in `kernel/KERNEL-SOURCE.md`). Upstream's kernel isn't kept in the image (release files must stay under 2 GiB); the first kernel update keeps the previous one as `.bak`. |
| **Kernel command line** | `ttm.pages_limit=3670016 amdgpu.sched_policy=2 amdgpu.vm_update_mode=0 amdgpu.cwsr_enable=0 amdgpu.bc250_gfx_eop_events=2` (as on the BC-250) `zswap.enabled=1 zswap.max_pool_percent=25 zswap.compressor=zstd`, and `kho=off udmabuf.size_limit_mb=16384`: the kernel's KHO keeps 1.5 GB as scratch for a kexec'd kernel, which the PS5 loader never starts, and that memory can't be pinned or given to the GPU; `kho=off` gives it back. The udmabuf limit lets the Flash Next engine map its expert pool ([AI](../docs/AI.md)). |
| **Swap** | No zram. On first boot a swap file in `var/swap` (32 GB on a 128 GB+ disk, 8 or 4 GB on smaller ones), zswap in front of it, `vm.swappiness=100` and friends in `/etc/sysctl.d/99-swap.conf`. |
| **Mesa** | From the `[bc250-cachyos]` repo, placed above the Arch and CachyOS repos: built for Zen 2 (`-mtune=znver2`) with the GFX1013 fixes. DirectMesh (mesh shaders) stays BC-250-only: on the Pro, task shaders and rasterizer discard hang the GPU in Vulkan CTS. |
| **Emulator repo** | `[bc250-emulators]` is set up, nothing is installed: `sudo pacman -S lichii-bc250 kytyps5-native-git`. |
| **Gaming Mode** | Steam runs as the user unit `steam-launcher.service` (`/usr/local/bin/ps5-steam-session`), so KytyPS5 can unload Steam while a game runs and bring it back afterwards, as on the BC-250. |
| **Fan** | A smoother curve (`/usr/local/sbin/ps5-fan-curve`, 50 °C → 40 … 80 °C → 125, 88 °C → 255): no jumps from silent to loud. |
| **Boost** | Off by default. `sudo ps5-boost on` builds `ps5_control` from [ps5-linux-tools](https://github.com/ps5-linux/ps5-linux-tools) and keeps boost on after a reboot; `sudo ps5-boost off` undoes it. |
| **Steam in the desktop** | Starts with the desktop (`/etc/xdg/autostart/steam.desktop`, `steam -silent -steamdeck`, as on the BC-250). Gaming Mode starts its own Steam. |
| **Boot session** | Every boot starts in Gaming Mode, as on SteamOS (`~/.config/ps5-boot-session` = `gamescope`, applied by `ps5-boot-session.service`). Switch to Desktop works as before until the next restart. To boot into the desktop instead, put `plasma` in that file; delete it to start in the mode used last (upstream's behaviour). |
| **Internal M.2** | `sudo ps5-install-m2` (below). |
| **Tools** | git, rsync, unzip, compsize (`ps5-boost` and `ps5-install-m2` install gcc when they need it). The `steam` user is in the `render` group (GPU compute through `/dev/kfd`). |
| **Updates** | `ps5-update`, `update.sh`, `update-kernel.sh`, `update-extras.sh` and `quiet-fan.sh` use this fork. `update-extras.sh` keeps the Steam user unit when it installs a newer Gaming Mode launcher. |

## Installing to the internal M.2

Boot the image from USB first, then:

```sh
sudo ps5-install-m2
```

It **erases the whole M.2** (PS5 games on it too), partitions it with `m2_init` from ps5-linux-tools at the
offset PS5 OS expects, creates the same btrfs layout (label `cachyos-m2`) and copies the running system.
The USB SSD stays the boot drive: the loader reads `bzImage`, `initrd.img` and `cmdline.txt` from it, and
`cmdline.txt` is switched to `root=LABEL=cachyos-m2` (the old one is kept as `cmdline.txt.usb-root`).
`grow-rootfs` is switched off on the M.2 copy, so its partition never grows into the area PS5 OS needs.
Back to the USB root: `sudo ps5-install-m2 --usb-root`.

## Loader

Each release also contains `ps5-linux-loader-<commit>.elf`: [soniciso1/ps5-linux-loader](https://github.com/soniciso1/ps5-linux-loader)
built from the commit in its name (GPL-3.0, that commit is the source). It includes PR #31 (PS5 OS Bluetooth
pairing export for the PS5 Pro), which isn't in a loader release yet. Built with Ubuntu 24.04, clang 18, lld 18
and PS5 Payload SDK v0.45 (`make -j1`); this setup reproduces Sonic's own release builds byte for byte.

## Building

On a Linux PC with Docker (about 20 GB free, the container is limited to 20 GB RAM):

```sh
image/build-image.sh                       # downloads the upstream image of BASE_TAG, uses kernel/*.tar.zst
image/build-image.sh --base <img or img.xz> --kernel <ps5-kernel-*.tar.zst>
```

The result is in `out/`.
