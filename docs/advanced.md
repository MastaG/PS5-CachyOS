# Advanced: official image, own kernel, repo files

[← Back to the README](../README.md)

## Using the official image instead

The official [ps5-linux CachyOS image](https://github.com/ps5-linux/ps5-linux-image/releases/tag/latest) works, but needs these fixes on top. Download and flash it as in [section 1](../README.md#1-flash-the-image):

```sh
wget https://pub-561df4012f1a46fbbdf618d5cc5941f6.r2.dev/ps5-cachyos.img.xz
sha256sum ps5-cachyos.img.xz     # must match the checksum on the release page
```

**Then run `sudo ./install.sh`** ([section 6](../README.md#7-extras-boost-fan-and-video)). It installs the core fixes below and offers the Wi-Fi driver. Reboot afterwards.

| Fix | Problem | Files |
|---|---|---|
| **Black screen lock** | Black screen below 4K (link drops below HBR3) | `dp-link-lock` + `.service` |
| **DualSense reconnect** | Adapter starts non-connectable, so the controller pairs once and never reconnects | `bt-connectable.service`, `dualsense.conf` |
| **Boot-order fix** | `ps5-stage-firmware.service` creates an ordering cycle, so systemd skips `systemd-sysctl` and `systemd-modules-load` | `DefaultDependencies=no` in that service |
| **zram swap** | No swap | `zram-generator.conf` (ram/2, zstd) |
| **Chrome video flags** | No hardware decode in Chrome | `chrome-flags.conf` |
| **Wi-Fi driver** (extra) | The kernel has no driver for the Wi-Fi chip | [ps5-linux-mwifiex](https://github.com/ps5-linux/ps5-linux-mwifiex) + `patches/0004` |

> [!IMPORTANT]
> **Reinstall the Wi-Fi driver after every kernel update** (`install.sh` → Wi-Fi driver), or Wi-Fi disappears.

**Not covered by `install.sh`:**
- **Switch to Desktop** in Gaming Mode may crash or leave a black screen on the official image. Use **boot to desktop** (`install.sh` extra, or `echo plasma > ~/.config/ps5-next-session` and reboot). Desktop → Gaming Mode is fine.
- **USB boot settings:** add `rootdelay=60 usbcore.autosuspend=-1` to `cmdline.txt`, plus `usbc_dp.enable=0` if your kernel has ps5-linux-patches `9bad84f` or newer ([details](../README.md#drive-not-found-at-boot)).
- **SteamOS-style Gaming Mode (with HDR and Steam's refresh rate setting) and desktop HDR** are only in this guide's image.

Check the boot-order fix: `journalctl -b | grep -i "ordering cycle"` should return nothing.

## Building your own kernel

Not needed for the image. This is an example build of Linux 7.2.3 + ps5-linux-patches `5f6b5d3` (the exact source of each image's kernel is in `KERNEL-SOURCE.md` on its release page). It needs about **15 GB free** and takes **30-60 minutes** on the PS5. Add `usbc_dp.enable=0` to `cmdline.txt` first ([section 8](../README.md#drive-not-found-at-boot)), or a USB-C SSD drops off.

**1. Build tools**
```sh
sudo pacman -S --needed base-devel bc pahole cpio git
```

**2. Get the sources** (keep this layout: the kernel config finds the video firmware in `../ps5-linux-patches/firmware`)
```sh
mkdir -p ~/kernel && cd ~/kernel
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.3.tar.xz
tar xf linux-7.2.3.tar.xz
git clone https://github.com/ps5-linux/ps5-linux-patches
git -C ps5-linux-patches checkout 5f6b5d3
```

**3. Patch, configure and build**
```sh
cd ~/kernel/linux-7.2.3
patch -p1 < ../ps5-linux-patches/linux.patch
for p in ~/PS5-CachyOS/patches/000[56]-*.patch; do patch -p1 < "$p"; done   # PS5 Pro Bluetooth (path to this repo)
cp ../ps5-linux-patches/.config .config
scripts/config --set-str LOCALVERSION "-ps5"    # names it 7.2.3-ps5, so it doesn't clash with the image's kernel
make olddefconfig
make -j"$(nproc)" bzImage modules               # the long part
```

**4. Install the modules and initramfs**
```sh
KVER=$(make -s kernelrelease)                   # 7.2.3-ps5
sudo make modules_install INSTALL_MOD_STRIP=1   # stripped, or the initramfs grows to ~300 MB
sudo mkinitcpio -k "$KVER" -g "/boot/efi/initrd-$KVER.img"
sudo cp arch/x86/boot/bzImage "/boot/efi/bzImage-$KVER"
```
The PS5 boots from `/boot/efi`, not `/boot`, so `make install` does nothing.

**5. Test it without rebooting** (kexec starts the new kernel from the running one, so you stay in Linux)
```sh
nmcli radio wifi off; sudo modprobe -r moal mlan; sudo modprobe -r btusb   # the chip doesn't reset across kexec
sudo kexec -l "/boot/efi/bzImage-$KVER" --initrd="/boot/efi/initrd-$KVER.img" --command-line="$(cat /boot/efi/cmdline.txt)"
sudo systemctl kexec
```
Once it's up, check `uname -r` says `7.2.3-ps5`, then reinstall the Wi-Fi driver for it: `sudo ./install.sh` → **Wi-Fi driver**.

**6. Make it the default** (only once the test worked)
```sh
sudo cp /boot/efi/bzImage /boot/efi/bzImage.bak
sudo cp /boot/efi/initrd.img /boot/efi/initrd.img.bak
sudo cp "/boot/efi/bzImage-$KVER" /boot/efi/bzImage
sudo cp "/boot/efi/initrd-$KVER.img" /boot/efi/initrd.img
```

**Going back:** copy `bzImage.bak` and `initrd.img.bak` back over `bzImage` and `initrd.img`. If Linux won't boot at all, do it from a PC: the `boot` partition is FAT32, so any PC can open it.

When you're done, `rm -rf ~/kernel` frees the 15 GB.

## What's in this repo

| Path | What it is | README section |
|---|---|---|
| `install.sh` | Checks the core fixes, offers the extras | [7](../README.md#7-extras-boost-fan-and-video), [official image](#using-the-official-image-instead) |
| `scripts/boot-to-desktop.sh` | Pick `plasma` or `gamescope` for the next boot | [4](../README.md#4-gaming-mode-and-the-desktop) |
| `scripts/fix-black-screen.sh` | TTY switch + link re-lock + double hotplug | [8](../README.md#black-screen) |
| `scripts/update.sh` | Updates an existing install in one go (kernel, fixes, Gaming Mode/Steam extras, FreeSync, optional fan curve, updater icon + daily check, system packages + Flatpaks), `--rollback` to undo steps 1–6 | [5](../README.md#5-updating) |
| `scripts/update-kernel.sh` | Installs the newest PS5 kernel without reflashing, `--rollback` to undo | [5](../README.md#5-updating) |
| `scripts/update-extras.sh` | Adds the Gaming Mode and Steam extras (no Steam update loop, desktop `-steamos3`, performance overlay, 16-thread shader pre-caching, refresh rate in Steam, HDR in Gaming Mode on FLAVA3, 12-bit colour icon), `--rollback` to undo | [5](../README.md#5-updating) |
| `kernel/ps5-kernel-*.tar.zst` | Newest PS5 kernel + modules for `update-kernel.sh`, with `.sha256` | [5](../README.md#5-updating) |
| `scripts/quiet-fan.sh` | Quieter fan curve + SoC temperature in the panel, `--remove` to undo | [7](../README.md#7-extras-boost-fan-and-video) |
| `files/usr/local/bin/dp-link-lock` | Locks the display link to 4 lanes HBR3 | [8](../README.md#black-screen) |
| `files/etc/systemd/system/dp-link-lock.service` | Runs it before the display starts | [8](../README.md#black-screen) |
| `files/etc/systemd/system/bt-connectable.service` | Lets the DualSense reconnect | [8](../README.md#wi-fi-and-bluetooth) |
| `files/etc/modules-load.d/dualsense.conf` | Loads `hidp` + `hid_playstation` | [official image](#using-the-official-image-instead) |
| `files/etc/systemd/zram-generator.conf` | zram swap, ram/2, zstd | [official image](#using-the-official-image-instead) |
| `files/home/steam/.config/chrome-flags.conf` | Chrome hardware decode flags | [7](../README.md#7-extras-boost-fan-and-video) |
| `files/home/steam/.config/ps5-next-session` | Session file (`plasma`) | [4](../README.md#4-gaming-mode-and-the-desktop) |
| `files/boot/efi/cmdline.txt.example` | Kernel command line | [8](../README.md#drive-not-found-at-boot) |
| `patches/0004-mwifiex-txpower-bounded-wait.patch` | Wi-Fi driver patch that stops a stuck firmware from freezing all networking | [8](../README.md#wi-fi-and-bluetooth) |
| `patches/0005-btusb-ps5-pro-viola-0e8d-3605.patch` | Kernel patch: PS5 Pro internal Bluetooth (HCI on interface 3, ACL on bulk OUT `0x0d`), from [QuartConz/ps5-pro-viola-bluetooth](https://github.com/QuartConz/ps5-pro-viola-bluetooth). Apply after `linux.patch` | [8](../README.md#wi-fi-and-bluetooth) |
| `patches/0006-bluetooth-l2cap-defer-security-block-while-encryption-pending.patch` | Kernel patch: the DualSense no longer disconnects right after connecting on the PS5 Pro (same source). Apply after `linux.patch` | [8](../README.md#wi-fi-and-bluetooth) |
| `files/etc/udev/rules.d/50-viola-bt-power.rules`, `files/etc/modprobe.d/viola-btusb.conf` | PS5 Pro Bluetooth: no USB autosuspend (it kills the internal USB controller) | [8](../README.md#wi-fi-and-bluetooth) |
| `files/usr/local/sbin/ps5-viola-bt-revive`, `files/etc/systemd/system/ps5-viola-bt-revive.service` | PS5 Pro Bluetooth: reloads btusb once if the adapter didn't power up after boot | [8](../README.md#wi-fi-and-bluetooth) |

The old kernel patches (`0001` Bluetooth, `0002`/`0003` 1440p @ 120 Hz) are gone: ps5-linux-patches `5f6b5d3` does all of that upstream.
