# Proton with FSR 4

> [!NOTE]
> Copied from [linux-cachyos-bc250](https://github.com/MastaG/linux-cachyos-bc250#fsr4-capable-proton-opt-in) (`bfb1d54b`), where these packages are
> built. The PS5 has the same GPU family (GFX1013) as the BC-250 board and the image ships the same
> Mesa, and the packages come from the `[bc250-cachyos]` repo the image already has. **Everything this
> page says was measured or tested "on a BC-250" was measured on that board, not on a PS5**: clocks,
> CU count and memory differ, so treat its numbers and recommended settings as a starting point.

Three packages, same idea: a Steam compatibility tool with everything FSR 4.1.1
needs on this hardware already inside it — the AMD FSR4 provider, OptiScaler,
OptiPatcher, [fakenvapi](https://github.com/optiscaler/fakenvapi) and a
known-good OptiScaler configuration.

| package | base | anti-cheat games | notes |
|---|---|---|---|
| `proton-cachyos-native-bc250` | CachyOS's Proton, from source | no | the fastest: no runtime container |
| `proton-cachyos-slr-bc250` | the same Proton, from source | **yes** | Steam Linux Runtime build |
| `protonge-latest-bc250` | GE-Proton, repacked | yes | tracks GE's own releases within hours |

Both CachyOS packages are compiled for this hardware (`-O3 -march=x86-64-v3
-mtune=znver2`) rather than repacked from someone's generic release. They differ
only in where they run: the native one talks to the system directly, which is
quicker, while the SLR one runs inside the Steam Linux Runtime — the environment
games with EasyAntiCheat or BattlEye require, and the one the native build cannot
offer.

```bash
sudo pacman -S proton-cachyos-native-bc250      # or
sudo pacman -S proton-cachyos-slr-bc250         # or
sudo pacman -S protonge-latest-bc250
```

All three can be installed at once (one `pacman -S` with all three names), and
all sit alongside the distro's own Proton packages.

> [!WARNING]
> **Don't install `linux-cachyos-bc250-meta`** on the PS5, the package linux-cachyos-bc250
> suggests for installing all three: it also pulls in the BC-250 kernel, which doesn't boot on a
> PS5. The PS5 kernel comes from this repo's updater. Restart Steam,
then pick **proton-cachyos-… (native, BC-250)**, **proton-cachyos-…
(BC-250)** or **GE-Proton <version> (BC-250)** under a game's Properties →
Compatibility.

**Anti-cheat, and why it needs saying.** These packages inject DLLs into the
prefix, which is exactly what anti-cheat software is built to notice, and
accounts have been banned for less. FSR4 and OptiScaler therefore switch
themselves off when a game is detected as using EasyAntiCheat or BattlEye. That
detection looks for Steam's layered anti-cheat runtimes and for the files both
products leave in a game directory — it is a safety net, not a guarantee. A game
whose anti-cheat arrives on first launch, or that lays its files out unusually,
will not be caught, and VAC leaves nothing to find at all. **If you play a game
with anti-cheat, set `PROTON_FSR4_UPGRADE=0 %command%` yourself rather than
relying on the detection**, or use a Proton without this payload in it.

If you accept the ban risk and want the upscaler in an anti-cheat game anyway,
switch the guard off: `BC250_FSR4_IGNORE_ANTICHEAT=1 %command%` for one game, or
for every game:

```bash
mkdir -p ~/.config/bc250-fsr4 && touch ~/.config/bc250-fsr4/ignore-anticheat
```

Delete that file to turn the guard back on. The launcher says in Steam's log
when it skipped the guard and why. Besides bans, anti-cheat may simply refuse
to start a game with OptiScaler loaded, so it will not work in every title.

**That is the whole setup.** No launch options, no DLLs to copy into game
folders, no environment variables. A game you have not set up yet starts with
**No upscaling**: the [upscaler menu](#the-upscaler-menu) at its launch lets you
pick one, and the [settings file](#settings-for-every-game) can change that
default or keep the menu away for every game.

**fakenvapi** is bundled and always active — there is no variable to enable it.
It stands in for `nvapi64.dll` so OptiScaler can reach AntiLag 2, Vulkan
AntiLag+, XeLL or LatencyFlex in games that would otherwise need NVIDIA Reflex.
OptiScaler picks whichever of those the hardware supports; on the BC-250 that
means the Reflex-shaped latency path works without an NVIDIA GPU. Unlike the
pinned OptiScaler build, fakenvapi is **tracked live**: a new upstream release
changes all three packages' fingerprints and they rebuild with it.

All three need the `vulkan-radeon` package from this repository: the provider calls
into FSR4 support that lives in our patched RADV, not in stock Mesa. They also
work under Heroic and Lutris, which run them through umu. (Flatpak Steam cannot
see them — its sandbox has its own `/usr`.)

## Launch options

Per game, if you want them:

```text
BC250_FSR4_DEBUG=1 %command%              # FSR4 watermark + OptiScaler log + PROTON_LOG
PROTON_FSR4_UPGRADE=0 %command%           # turn the packaged FSR4 upgrade off
PROTON_USE_OPTISCALER=freefg-hlxdlss %command%  # force one of the upscalers by name
                                          # every launch (see below); skips the menu
PROTON_OPTISCALER_MENU=1 %command%        # show the upscaler menu again after "Save selection"
PROTON_OPTISCALER_MENU=0 %command%        # skip the menu, start with this game's current choice
BC250_OPTISCALER_EXTRA="A.B=c;D.E=f"      # override individual OptiScaler settings
PROTON_OPTISCALER_NAME=dxgi.dll %command% # load OptiScaler as dxgi instead of winmm
BC250_GAME_PRESET=0 %command%             # no known per-game settings (see Game presets)
BC250_GAME_PRESET=everything %command%    # apply all of this game's known settings again
```

## The upscaler menu

Every game launch first shows a small menu: the upscaler (**No upscaling**, where
a new game starts; **FreeFG + HLX FSR 4**; **FreeFG + HLX DLSS** with a choice of
**DLSS Model E** or **DLSS Preset K**; **FreeFG + HLX FSR 4 Full**; **FreeFG +
FSR 4 RC12**), **GPU spoofing**, **Enable frame generation**, **Use the game's
DLSS frame generation**, and **Save selection for next time**.
It works with a controller (Steam Controller, PS5 pad; D-pad or stick to move, A
to select, Start to start the game), with mouse and keyboard, in Gaming Mode and
on the desktop, and it waits until you choose.

- The upscaler the game is on now is pre-selected, read from the game's
  `OptiScaler.ini`: pick another one in the OptiScaler overlay (Insert, the
  Upscalers list, *Save Settings*) and the menu shows that one at the next
  launch. The frame generation box likewise shows what the game really does
  now. Pressing Start without touching anything changes nothing. An upscaler
  the menu does not list (XeSS, say, picked in the overlay) gets a row of its
  own, **Keep the overlay's choice**.
- Frame generation starts **off**: a new game gets `FrameGen.Enabled=false`
  written into its `OptiScaler.ini`. Tick **Enable frame generation** to turn it on, or turn it on
  in the OptiScaler overlay (Insert, Frame Gen mode, *Save Settings*); either way
  the box is ticked at the next launch, because it reads the game's own ini.
  The generator is already wired, so nothing else needs picking: FreeFG's XeFG,
  unless you picked something else in the overlay.
- Choosing another upscaler changes only that (`[Upscalers] Dx12Upscaler`):
  every upscaler is in the game's files already, so your other OptiScaler
  settings stay.
- **Use the game's DLSS frame generation** takes the game's own DLSS Frame
  Generation as the input for FreeFG's frame generation
  (`FrameGen.FGInput=dlssg`) instead of OptiFG: its motion vectors and its image
  without the HUD, so the UI is not interpolated. Ticking it also sets GPU
  spoofing to **On** (a game only offers DLSS FG on an "NVIDIA" card) and
  enables frame generation; then turn DLSS Frame Generation on in the game's own
  menu. It is the player's pick, so a known game's preset does not change it back.
  Unticked, the input returns to OptiFG.
- **GPU spoofing (DXGI)**: Auto lets OptiScaler decide (on when the game ships
  `nvngx_dlss.dll`, which is what brings its DLSS option); On and Off force it
  for this game. Like the frame generation box, it shows the prefix's current
  value and is written only when you change it.
- **No upscaling** runs the game as it ships, the same as
  `PROTON_FSR4_UPGRADE=0`: no FSR4 and no OptiScaler. It leaves the game's
  OptiScaler files and settings alone for when you come back.
- **Save selection** skips the menu from then on. `PROTON_OPTISCALER_MENU=1
  %command%` shows it again. `PROTON_OPTISCALER_MENU=0 %command%` skips it
  without saving anything: the game starts with its current choice (the last one
  picked in the menu or the overlay). A launch option that names an upscaler
  (`PROTON_USE_OPTISCALER=...`) skips it too. Anti-cheat games never see it,
  unless the anti-cheat guard is switched off (`BC250_FSR4_IGNORE_ANTICHEAT=1`
  or `~/.config/bc250-fsr4/ignore-anticheat`).
- No display, or `python-gobject`, `gtk4` or `sdl3` missing: no menu, and the
  game starts with its current choice (a new game: No upscaling, or the
  settings file's default).
- **Force apply known settings** appears only for a game the preset database
  knows (next section). Ticked, it applies them again over what the prefix has
  now: **Apply matching only** (the default) or **Apply everything**.

## Settings for every game

Steam has no launch option for all games, so the menu reads
`~/.config/bc250-fsr4/settings` (`key = value` lines, `#` starts a comment):

```ini
# Never show the menu by itself (PROTON_OPTISCALER_MENU=1 still shows it for one game).
menu = 0
# What a game you have not set up yet starts with:
#   off                  No upscaling (the default)
#   freefg-hlxfsr4       FreeFG + HLX FSR 4
#   freefg-hlxdlss       FreeFG + HLX DLSS, DLSS Model E
#   freefg-hlxdlssk      FreeFG + HLX DLSS, DLSS Preset K
#   freefg-hlxfsr4full   FreeFG + HLX FSR 4 Full
#   freefg               FreeFG + FSR 4 RC12
default = freefg-hlxfsr4
```

```bash
mkdir -p ~/.config/bc250-fsr4 && printf 'menu = 0\n' > ~/.config/bc250-fsr4/settings
```

`default` only decides how a new game starts (no menu choice and no OptiScaler
files in its prefix yet); a game you have played keeps its own choice. With
`menu = 0` and the default `off`, these packages behave like their upstream
Proton until you turn OptiScaler on for a game (`PROTON_OPTISCALER_MENU=1` once,
or `PROTON_USE_OPTISCALER=...`). A line the launcher does not understand is
skipped and named in Steam's log.

## Game presets

Known working OptiScaler settings per game are applied by themselves. They come
from two sources, merged every night into one file on the
[`bc250-game-presets`](https://github.com/MastaG/linux-cachyos-bc250/releases/tag/bc250-game-presets)
release:

- [FreeFG](https://github.com/daniel-h-0/freefg)'s recipes for the games its
  maintainers tested on a BC-250, with their OptiScaler settings (including the
  `XeFG.*` and `FrameGen.*` ones), frame-generation input and launch options
  such as `-dx12`. These always win.
- The [OptiScaler wiki](https://github.com/optiscaler/OptiScaler/wiki/), about
  750 games: settings, the conditions they come with ("for DLSS inputs", "on
  AMD/Intel"), and the DLL name OptiScaler needs where that is unusual.

The launcher downloads the file at most once a day into
`~/.cache/bc250-fsr4/game-presets.json.gz` and keeps using the old copy when it
cannot (offline, GitHub down): a game never waits more than a few seconds for it
and never fails to start because of it. The game is recognised by its Steam app
id, its `.exe`, or its name.

- **When:** on a fresh `OptiScaler.ini` only — a new prefix, or after switching
  upscaler, which starts fresh anyway. After that the INI is yours: what you
  change in the OptiScaler overlay stays. Launch options and the DLL name are
  applied on every launch, since they live nowhere else.
- **Matching** (the default): the tested BC-250 settings, plus the wiki's that
  have no condition or whose condition holds here (AMD, Linux, FSR4, the
  frame-generation input and output of the upscaler you picked). Settings
  OptiScaler already applies by itself are left out. When the wiki's tester ran
  OptiScaler under another DLL name than the package's `winmm.dll` (usually
  `dxgi.dll`), that name is used; a `PROTON_OPTISCALER_NAME` you set still wins.
- **Everything**: every setting the game has, whatever its condition (where the
  wiki gives several values for one setting, the matching one still wins). For a
  game that does not work with matching only. It can also apply fixes meant for
  NVIDIA or for another input, so try it rather than start with it.
- **Never touched**: settings this upscaler's OptiScaler does not have,
  the package's own wiring (library paths, the upscaler, the frame-generation
  output, logging, the overlay itself) and the frame generation on/off switch,
  which stays the menu's.
- What was applied is in `<compatdata>/bc250-game-preset.json` and in the game's
  log (`bc250-fsr4: applied the matching preset for ...`).

`PROTON_OPTISCALER_NAME` is for one specific symptom: FSR4 quietly does nothing
in a game that has a mod loader, an ASI loader, or anything else of its own
installed as `winmm.dll`. OptiScaler is proxied as `winmm` here, so in that game
the game's own file wins and the upscaler never loads. Point it at another
import the game does not use — `dxgi.dll` is the usual one, and is upstream
protonfixes' own default:

```text
PROTON_OPTISCALER_NAME=dxgi.dll %command%
```

The payload is the same pinned OptiScaler either way. The first launch with a
new name makes a link of that name next to the pinned `winmm.dll` in the prefix
(`drive_c/windows/system32/umu/`), because Wine looks for the requested name
there, and the matching `WINEDLLOVERRIDES` entry follows the name automatically.
The link always points at the pinned file, so it follows `PROTON_USE_OPTISCALER`
variant switches. Confirm it worked with `BC250_FSR4_DEBUG=1` and look for the
watermark. Needs a Proton package built after 2026-10-06; earlier builds ignored
the name unless you linked the file yourself.

OptiScaler answers to a fixed set of names — `dxgi.dll`, `winmm.dll`,
`version.dll`, `dbghelp.dll`, `d3d12.dll`, `wininet.dll`, `winhttp.dll` — so pick
one of those, and one the game does not already have a file for. Anything else
just means OptiScaler never loads.

This is unrelated to the `Spoofing.Dxgi` setting, despite the shared word. The
proxy name decides which import the loader resolves to OptiScaler; `Spoofing.Dxgi`
decides whether OptiScaler reports a spoofed GPU to the game once it is running.
This package seeds that one with `auto` (see below).

`BC250_OPTISCALER_EXTRA` is the per-game switch that is still enforced on every
launch. The shipped preset only seeds a prefix that has no answer of its own (see
below), so what the overlay wrote stays put; this is how you pin a value for one
game without touching the file. It takes `Section.Option=value` pairs separated
by `;` and merges them over everything else for that game only:

```text
BC250_OPTISCALER_EXTRA="Spoofing.Dxgi=auto;FrameGen.Enabled=true" %command%
```

A key the shipped OptiScaler build does not define stops the launch and names
it, rather than being silently ignored.

**No DLSS option in a game's menu?** A fresh prefix starts with
`Spoofing.Dxgi=auto`, as FreeFG's own installer leaves it:
OptiScaler then reports an NVIDIA GPU whenever the game ships its own
`nvngx_dlss.dll`, and games gate their DLSS row on seeing one. Without that file
it reports the BC-250, and the OptiScaler overlay says `Spoof: Off`. A prefix
from an older package can still hold the old `false` (that value counts as an
answer and is kept). Set **GPU spoofing** to **On** in the upscaler menu, or per
game:

```text
BC250_OPTISCALER_EXTRA="Spoofing.Dxgi=true" %command%
```

Some games crash with spoofing on; **Off** in the menu forces it off for that
game. `Spoofing.VulkanExtensionSpoofing` stays off: that one was behind the
"DX12 not supported" report.

The upscaler itself does not need spoofing. With it off the game's own FSR or
XeSS option is the input and OptiScaler translates it — the overlay shows
`Input: FFX` or `Input: XeSS`.

The DLSS path is still often the better input: OptiScaler translates it the same
way, it brings NVIDIA Reflex with it, it has measured faster than the game's own
FSR input on a BC-250, and it is reported working in The Last of Us Part II and A
Plague Tale: Innocence. The fuller version, which also answers the
driver-version question below:

```text
BC250_OPTISCALER_EXTRA="Spoofing.Dxgi=true;Spoofing.Registry=true" %command%
```

Then pick DLSS in the game's own graphics menu.

The OptiScaler overlay owns the whole preset now. OptiScaler ships every key as
`auto`, a key that still says `auto` is nobody's answer, and the preset writes
only those: change one in the overlay, save, and it sticks from then on. A
package update that ships a new OptiScaler build resets the file and seeds it
again, and a launch option still beats both. A variant's own library paths and
the debug keys are what stays enforced on every launch — those are the things
*Save Settings* cannot win.

Two follow-ups, both seen on a BC-250 in The Last of Us Part II:

- The game may then warn that no graphics card was found, or that your RTX 4090
  is on the wrong driver version. DXGI spoofing only changes what the adapter
  reports; that game also reads the registry. Add `;Spoofing.Registry=true`,
  which spoofs vendor, device and driver version there, and `;Spoofing.User32=true`
  if the first complaint survives. The game runs either way — these are warnings,
  not failures.
- If spoofing brings back "DX12 not supported" in an Unreal Engine game, that is
  the error `Spoofing.UEIntelAtomics=true` exists for. Try it before giving the
  spoofing up.

`BC250_FSR4_DEBUG=1` is the one to reach for when something looks wrong — it
puts the FSR4 watermark on screen and writes a Proton log, which turns "FSR4
doesn't seem to work" into something diagnosable.

Without it the package writes no logs, except HelixSR's own `helixsr.log`, which
stays on because its author asks for it with every report. That includes fakenvapi, which
logs to `fakenvapi.log` beside its own DLL by default; the package ships a
`fakenvapi.ini` that turns it off. If you are chasing a Reflex or latency problem
and want it back, edit that file in the prefix — it is not checksummed, so the
change sticks:

```text
<prefix>/drive_c/windows/system32/umu/OptiScaler/fakenvapi.ini
```

## The upscalers

One payload carries five upscalers, all on [FreeFG](#freefg-xess-frame-generation-for-the-bc-250-the-default)
(its OptiScaler build with Intel's XeSS frame generation, sped up for the BC-250,
off until you turn it on). Pick one in the menu, or in the OptiScaler overlay
(Insert, the Upscalers list for DirectX 12, then *Save Settings*); the overlay
lists them as below, and the menu shows the overlay's pick at the next launch.

| Menu | In the OptiScaler overlay | Launch option (forces it every launch) |
|---|---|---|
| FreeFG + HLX FSR 4 | `FSR 3.X/4`, with HLX FSR 4 in its *FFX Upscaler* list | `PROTON_USE_OPTISCALER=freefg-hlxfsr4` |
| FreeFG + HLX DLSS, DLSS Model E | `hlx-dlss` | `PROTON_USE_OPTISCALER=freefg-hlxdlss` |
| FreeFG + HLX DLSS, DLSS Preset K | `hlx-dlss-k` | `PROTON_USE_OPTISCALER=freefg-hlxdlssk` |
| FreeFG + HLX FSR 4 Full | `HLX FSR 4 Full` | `PROTON_USE_OPTISCALER=freefg-hlxfsr4full` |
| FreeFG + FSR 4 RC12 | `FSR 4 RC12` | `PROTON_USE_OPTISCALER=freefg` |

`PROTON_USE_OPTISCALER=freefg-all` turns OptiScaler on without forcing an
upscaler (the overlay's pick stays), and `PROTON_USE_OPTISCALER=0` turns it off.

The two HLX DLSS entries are called `hlx-dlss` and `hlx-dlss-k` because FreeFG's
OptiScaler recognises HLX DLSS by a folder name starting with `hlx-dlss` to hand
it the game's input type (FreeFG's own names). Until 2026-11-12 Preset K was
`HLX DLSS Preset K`; a game set to it moves to `hlx-dlss-k` by itself.

- **HLX FSR 4** (the payload's first pick): AMD's FSR 4 network on the
  faster pipeline of [HelixSR](https://github.com/lonewolf0622/HelixSR) 3.3.0 by
  lonewolf0622 (the DirectMesh author), an FSR 3.1 drop-in as OptiScaler's
  FidelityFX upscaler. On a BC-250 in Shadow of the Tomb Raider it took 1.17 ms
  from 720p to 1080p, against 3.6 ms for the fork's RC11. Its shaders are built
  from AMD's FSR SDK 2.4.0 (FSR 4.1.2, MIT); since 3.2.1 it no longer ends the
  game under Proton 11.0 on a BC-250. AMD's own FidelityFX upscaler from the
  same release (FSR SDK 2.4.0, FSR 4.1.2) sits beside it as
  `amd_fidelityfx_upscaler_dx12.amd.dll`, its fallback for what its own runtime
  does not cover. It also carries the Direct3D 11 games (OptiScaler's `ffx_12`
  route), whichever DirectX 12 upscaler is picked. Vulkan games get HelixSR's
  Vulkan build of HLX FSR 4 natively (`OptiScaler/custom/HLX FSR 4/ffx_vk`),
  also whichever upscaler is picked; before, they went through OptiScaler's
  DirectX 12 bridge. If a Vulkan game misbehaves, the bridge is still there:
  `BC250_OPTISCALER_EXTRA="Upscalers.VulkanUpscaler=ffx_12" %command%`.
- **HLX DLSS, DLSS Model E**: HelixSR's NVIDIA DLSS neural network (Model E)
  as ordinary DirectX 12 compute shaders, so no NVIDIA GPU or driver is needed,
  set up the way FreeFG's own installer does for `--upscaler hlx-dlss`. Pick DLSS,
  FSR or XeSS in the game; OptiScaler hands the frames to HLX DLSS in Direct3D 12
  games. HelixSR's int8 path is
  off (`Int8 = off` in its `helixsr.ini`): the BC-250 has no fast int8. On a
  BC-250, a good starting point is 1440p output, medium to high settings and
  HLX DLSS at Quality (960p render), which often runs well enough without frame
  generation.
- **HLX DLSS, DLSS Preset K**: HelixSR 3.3.0's DLSS 4 Preset K network in a
  folder of its own (`OptiScaler/custom/hlx-dlss-k/dlss/`, its kernels and
  weights beside it). Since FreeFG 1.4.0 it gets the game's input type too, as
  Model E does. Sharper than Model E and a little slower (2.54 ms at 1080p
  Quality on a BC-250), but it can sparkle on foliage and showed artifacts and
  ghosting in our tests; some players like it. With the Steam overlay on, a game
  can freeze at startup: turn the overlay off for that game if it does.
- **FSR 4 RC12**: the BC-250 FSR4 fork's
  [v4.0.0-rc12](https://github.com/daniel-h-0/bc250-fsr4-fork/releases/tag/v4.0.0-rc12)
  bridge (`4.1.1r12`, by daniel-h-0), the build FreeFG pins itself: made for and
  measured on this hardware, the RC8/RC9 shader work extended to the 1080p and
  8K context families. `BC250_FSR4_DEBUG=1` puts its watermark on screen. It is
  an OptiScaler custom upscaler here (`OptiScaler/custom/FSR 4 RC12/ffx/`),
  since HLX FSR 4 has the FidelityFX slot.
- **HLX FSR 4 Full**: HelixSR 3.3.0's full FSR 4.1.2
  network, sharper and slower than HLX FSR 4 (about 2.15 ms at 1080p Quality on
  a BC-250). Installed the way HelixSR's own setup does it: an OptiScaler
  custom upscaler in `OptiScaler/custom/HLX FSR 4 Full/ffx/` with its own
  `hlx_fsr4.ini`. `DeepReuse = 1:2` or `1:4` in that `hlx_fsr4.ini` is
  faster with some ghosting in motion; `exact`, the default, has none. Games
  that draw to a 10-bit (R10G10B10A2) output, Ghost of Tsushima among them,
  showed a black image with 3.2.1's Full
  ([HelixSR #187](https://github.com/lonewolf0622/HelixSR/issues/187)); 3.3.0
  fixes that, and its Full network kernels are about 2.5% faster on a BC-250.
  If you still see a black image, Full's `hlx_fsr4.log` beside it helps.

Until 2026-11-08 each upscaler was a variant of its own, and switching meant
starting the game's OptiScaler settings over. A game that ran one of those
moves to the one payload on its next launch with the same upscaler picked; its
`OptiScaler.ini` starts fresh that one time. The older names still work as
launch options too: `hlxfsr4` is HLX FSR 4, `hlxdlssk` DLSS Preset K, the
HelixSR ones (`helixsr`, `helixsr-ffx`, `freefg-helixsr`) DLSS Model E, and the
stock nightly's bridges and `optiscaler` FSR 4 RC12. Once
OptiScaler's nightly has merged FreeFG's changes, FreeFG's own OptiScaler build
gives way to the nightly.

On a game launch the wrapper also removes every file and folder an older
package left in the prefix that the payload no longer has (`.ini` files and
logs included, which Proton's own replacement keeps), so a game never runs with
pieces of two payloads.

None of them ever uses a DLL from the game's own folder: the upscaler always
comes from the pinned payload, and the game's FSR/DLSS DLLs are only the API it
talks to. HLX DLSS writes `helixsr.log` beside itself
(`system32/umu/OptiScaler/custom/hlx-dlss/dlss/`), HLX FSR 4 `HLX_FSR.log` in
`system32/umu/OptiScaler`; attach them when reporting a HelixSR problem.

Provenance, stated plainly: HelixSR is free to use under its own freeware
licence (its source is not published). The DLSS network it runs is, per its
author, NVIDIA's property and not covered by any licence here; its release
does not contain it: its setup script builds it from NVIDIA's public DLSS
310.7.0 DLL. HLX FSR 4's shaders ship built in the release. We ran the setup
script once and mirrored the result (`HelixSR-3.3.0-20261112-network.zip`), so the Proton
packages need no setup step and nothing is downloaded at game launch. HelixSR and
the RC12 bridge are unsigned; each is pinned by SHA256 and its origin is written
into the prefix (`Licenses/THIRD-PARTY-UPSCALER.txt`, notices under
`Licenses/<version>/`), so they are reproducible, not vouched for.

Design and packaging details are in [docs/FSR4-PROTON.md](https://github.com/MastaG/linux-cachyos-bc250/blob/main/docs/FSR4-PROTON.md)
and [packages/bc250-fsr4-common/README.md](https://github.com/MastaG/linux-cachyos-bc250/blob/main/packages/bc250-fsr4-common/README.md).

## FreeFG: XeSS frame generation for the BC-250 (the default)

Every upscaler runs on [FreeFG](https://github.com/daniel-h-0/freefg) 1.4.0 by
daniel-h-0. Frame generation is Intel's XeSS FG (XeFG): Intel's unmodified
runtime generates the frames, and FreeFG's wrapper runs part of its GPU work with
FreeFG's own shaders, which are faster on the BC-250 (its author measured +21% in
Cyberpunk 2077 at 2×) and gave the same pixels where compared. FreeFG's Vulkan
layer paces the frames for VRR displays (under gamescope only). See
[the upscalers](#the-upscalers) for what it upscales with.
OptiScaler's files around FreeFG's build are those of the nightly FreeFG pins
(2026-10-25).

A game that ran a variant that is gone now (HelixSR Scaler, a bridge on the stock
nightly, or one of the one-upscaler variants) starts fresh on its next launch:
its old files and its `OptiScaler.ini` are removed, so settings saved in the
OptiScaler overlay for it are reset once, and the upscaler it had stays picked.

FreeFG has optional generated-frame scaling since 1.1.4 (cheaper in 1.1.5; 50–100% or a resolution
limit, with a choice of filters); the default, and what this package leaves it
at, is generated frames at full output size. It is set in FreeFG's
`settings.ini` beside the game's `.exe`, which this package does not ship.

What the variant sets, as FreeFG's installer would for its OptiScaler route:
frame generation wired for XeFG output at 2× but off until you enable it (the
upscaler menu), borderless instead of exclusive
fullscreen (XeFG does not interpolate in exclusive fullscreen), Reflex forced on
for XeLL, and OptiFG as the input (`FrameGen.FGInput=upscaler`, which works in
any game whose upscaler OptiScaler sees). FreeFG's own installer picks the input
per game from its recipes; here a game that has DLSS or FSR frame generation can
ask for it instead, with the menu's **Use the game's DLSS frame generation**
box, or per launch:

```text
BC250_OPTISCALER_EXTRA="FrameGen.FGInput=dlssg" %command%
```

Choose the upscaler in the game as usual, and leave the game's own frame
generation off with the OptiFG input. It is DirectX 12 only, and only the
first XeFG context of a game is sped up.

Every variant also loads [MFG Unlocker](https://github.com/dashdogy/MFG-Unlocker)
1.7.0 by dashdogy (MIT) as an OptiScaler plugin (FreeFG's author used 1.6.0 for
3× and 4× on the BC-250; 1.7.0 keeps 1.6.1's frame pacing under Wine/Proton). With frame generation on, OptiScaler's
overlay (Insert) then offers 3× and 4× in its XeFG multiplier; the default stays 2×, and a
multiplier saved there is kept across launches. Higher factors cost more GPU
time per output frame, so they suit games with headroom and a high-refresh
display.

GTA V Enhanced (Story Mode) works with FreeFG since 1.2.0: its OptiScaler keeps
the Social Club overlay out of frame generation. The per-game presets turn frame
generation on for it. FreeFG's own recipe also sets
`[BC250] RequireArgument=-nobattleye`, which keeps OptiScaler inactive unless the
game is started with `-nobattleye`; on a BC-250 that option is not needed, so
the presets leave it unset. The game ships BattlEye, so the launcher keeps
OptiScaler out until you accept that for it:
`BC250_FSR4_IGNORE_ANTICHEAT=1 %command%`. For GTA Online, keep OptiScaler out
of it with `PROTON_FSR4_UPGRADE=0 %command%` instead.

Status: experimental, though FreeFG has been in the default since 2026-10-26. Its author qualifies
each release on a BC-250 in menus and benchmarks; here it was tried in
Spider-Man 2 and Shadow of the Tomb Raider. Its logs, `BC250-MFG.log` and
`BC250-XeFG-fast.log`, are in `system32/umu/OptiScaler` of the prefix; report
FreeFG problems [to FreeFG](https://github.com/daniel-h-0/freefg/issues). The
package ships FreeFG's release files unchanged, pinned by SHA256: its
OptiScaler build (GPL-3.0; source at
[daniel-h-0/OptiScaler](https://github.com/daniel-h-0/OptiScaler/releases/tag/bc250-4d0c0b9-r1),
and `freefg-1.4.0-source.zip` is mirrored beside the package inputs), its
wrapper, shaders and layer (MIT). Intel's XeFG and XeLL runtimes are the ones in
the pinned OptiScaler nightly, byte-identical to what FreeFG pins.

---
