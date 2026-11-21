# Kernel 7.3.5-pc8fe-bc1: source

Built from (in this order):

1. Linux **7.3.5** (kernel.org tarball)
2. [ps5-linux-patches](https://github.com/ps5-linux/ps5-linux-patches) `c8fe83a4db9d87b1d95cde83223069bae8256988` (`linux.patch`, its `.config`)
3. This repo's `patches/0005`-`0007` (from upstream [abrocoma/PS5-CachyOS](https://github.com/abrocoma/PS5-CachyOS): PS5 Pro Bluetooth, L2CAP, HDMI 75 Hz)
4. This repo's `patches/0008`-`0016`: GFX1013 compute (KFD) fixes from linux-cachyos-bc250 and the PS5 Pro (`0x13DA`) gates

Config: ps5-linux-patches' `.config`, `LOCALVERSION=-pc8fe-bc1`, `MEDIA_SUPPORT=m`, `USB_VIDEO_CLASS=m`.
Wi-Fi: `moal`/`mlan` from [ps5-linux-mwifiex](https://github.com/ps5-linux/ps5-linux-mwifiex) `6e87c85689a328e79885f31a69e41a1406f8c268`
(its RTNL bounded-wait fix makes this repo's `patches/0004` unnecessary).
Compiler: GCC 16.2.1 20260810 (Arch Linux container). Build steps: [docs/advanced.md](../docs/advanced.md#building-your-own-kernel).
