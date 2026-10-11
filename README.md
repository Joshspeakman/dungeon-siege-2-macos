# Dungeon Siege II for Apple Silicon Macs

Dungeon Siege II (GOG release 2.3), statically recompiled from your own copy into native arm64 code and run on Metal,
as [dungeon-siege-macos](https://github.com/Joshspeakman/dungeon-siege-macos) does for Dungeon Siege 1. No Wine, no
Rosetta, no emulator. Nothing from the game is in this repository: the build regenerates everything locally from your
copy, and the game folder is only read.

**Status: beta** ([releases](https://github.com/Joshspeakman/dungeon-siege-2-macos/releases)). Single player is
playable:

- the main menu, hero creation, the intro movie and opening cutscene;
- gameplay: the world, characters, the HUD, dialogue, combat, spells and powers; saving and loading;
- the display's own resolution, up to 120 fps, in real macOS full screen with Game Mode, with a larger interface on
  high-resolution displays if wanted;
- the game's shader effects (Options → Video → Shaders), translated from its HLSL to Metal;
- a View Distance setting that pushes out each area's fog, like the SeeFar mods;
- sound (Miles) and movies (Bink), recompiled from the DLLs in your game folder;
- multiplayer switched back on (the GOG release disables it): LAN games (host, join, play together) with no CD key and
  no online service; the internet lobby signs in to OpenSpy with an original retail CD key.

```sh
xcode-select --install                     # once: clang, git and python3
git clone https://github.com/Joshspeakman/dungeon-siege-2-macos.git && cd dungeon-siege-2-macos
./install.sh --gog-installer ~/Downloads/setup_dungeon_siege_2_*.exe   # needs: brew install innoextract
#   or: ./install.sh --game-dir "/path/to/Dungeon Siege 2"
open ~/Applications/"Dungeon Siege II Native.app"
```

## Requirements

- A Mac with **Apple Silicon** (M1 or later). The installer stops on an Intel Mac. The app needs **macOS 13** or newer.
- The **Xcode Command Line Tools**: `xcode-select --install` (installs `clang`, `git` and `python3`). The full Xcode
  isn't needed.
- On the first build the recompiler makes a Python environment in `recomp/.venv` and installs `capstone` and `unicorn`
  into it with pip, so the first install needs an internet connection.
- Time: the recompile takes about 10 minutes on an M1 Pro, and runs again on every update.
- Optional: [Homebrew](https://brew.sh) and `brew install innoextract`, for installing from the GOG offline installer.
- **Dungeon Siege II, GOG release 2.3** (offline installer build 37617). The installer checks the SHA-256 of
  `DungeonSiege2.exe` and refuses anything else:

  | Edition | `DungeonSiege2.exe` SHA-256 |
  |---|---|
  | GOG 2.3 | `c17e1cc9e01b5d2439a92e06b905040379ad4bb8618b822582c46f5fa29db4e2` |

  The Steam release, retail discs, other patch levels, modified executables and the Broken World expansion (a separate
  executable) are not supported.

## Getting the game files onto the Mac

| You have | Command |
|---|---|
| The GOG offline installer (`setup_dungeon_siege_2_*.exe`, from your GOG library's "offline backup game installers") | `./install.sh --gog-installer ~/Downloads/setup_dungeon_siege_2_*.exe`: unpacked with `innoextract` into the data folder (`gog-extract`), and the app reads the game from there |
| The game installed or unpacked somewhere (for example copied from a Windows PC) | `./install.sh --game-dir "/path/to/Dungeon Siege 2"` (the folder that holds `DungeonSiege2.exe`) |

With `--game-dir` the app remembers that folder and reads the game's data from it every time it starts, so leave it
where it is. It is never changed.

## Installing

```sh
git clone https://github.com/Joshspeakman/dungeon-siege-2-macos.git
cd dungeon-siege-2-macos
./install.sh --gog-installer ~/Downloads/setup_dungeon_siege_2_*.exe
```

This recompiles the game and installs **`~/Applications/Dungeon Siege II Native.app`** (shown as *Dungeon Siege II*).
Keep the cloned folder: the app's Updates row rebuilds from it. On an interactive first install the script ends by
offering to store a CD key for online play; press Return to skip (LAN games don't need one).

Every `install.sh` option:

| Option | What it does |
|---|---|
| `--game-dir DIR` | Build from a game folder holding `DungeonSiege2.exe`. |
| `--gog-installer FILE` | Unpack the GOG offline installer into `<data>/gog-extract` and build from that. |
| `--cd-key` | Ask for the 25-character product key of your own original retail copy and store only its hash, for the internet lobby (`DS2_CDKEY=<key>` gives it without the prompt). Works on its own or with a game option. |
| `--cd-key --reg-file FILE` | Write that hash as a `.reg` file for a Windows (or Wine/Proton) player to import instead. Nothing on this Mac changes. |
| `--nightly` | Install **Dungeon Siege II Nightly.app** next to the stable app, built from the `nightly` branch (see *Updating*). |
| `--app-dir DIR` | Where the app goes (default `~/Applications`). See the updater limitation below. |
| `--data-dir DIR` | Where saves, settings and logs go (default `~/Games/DungeonSiege2Native`). See the updater limitation below. |

With no game option, `install.sh` rebuilds from the game folder the installed app already uses. The install downloads
the launch window's banner (Dungeon Siege II's key art from Steam's store) for your Mac; `DS_NO_DOWNLOADS=1` skips it,
and the window then shows the game's own logo.

### What goes where

| Location | Contents |
|---|---|
| Your game folder | Only read, never changed. |
| `~/Applications/Dungeon Siege II Native.app` | The recompiled game, built on your Mac from your copy. |
| `~/Games/DungeonSiege2Native` | The data folder: saves and the game's settings (`drive_c/Users/player/Documents/My Games/Dungeon Siege 2`; multiplayer parties in `Save/MultiPlayer`), the launch window's choices, the stored CD-key hash (`cdkey-hash.txt`), the log (`DungeonSiege2Native.log`), update output (`update.log`), crash reports (`CrashReports/`), the Test Lab's own copy of your saves (`test-lab/`), and the unpacked game for `--gog-installer`. |
| The cloned repository | The recompiler, its Python environment (`recomp/.venv`), the generated code (`recomp/work`, never committed) and the update builds (`build/stable`, `build/nightly`). |

## The launch window

Opening the app shows the launch window first: the game's key art, the Game row, then Display, Graphics, Online and
Updates as buttons that show what's chosen. Press **Play** (or Return); choices are remembered.

| Setting | Choices |
|---|---|
| Game | **Dungeon Siege II** (the campaign, and multiplayer from the main menu) · **Test Lab** (below) |
| Display → Resolution | the display's own resolution (recommended), its full Retina size, and standard sizes that fit |
| Display → Interface Size | 100% to 300%: the game runs at the resolution divided by it (a larger interface), and the screen is drawn at the full resolution, so the world stays sharp |
| Display → Frame Rate | **Automatic** (120 fps on a 120 Hz display, 60 in the heaviest scenes) · 120 · 60 · 30 · Unlimited |
| Display → View Distance | **Original** · Far (125%) · Farther (150%, like SeeFar) · Very Far (200%) · Horizon (250%) · Maximum (300%) |
| Display → Gamma, Notch | the game's brightness; on a Mac with a notch, **Hide the Notch** (the picture below the camera) or **Around the Notch** (the whole display) |
| Graphics | the game's own Shaders (Game's Choice until one is picked, Off, Standard, Advanced), Shadows, Texture Filtering and Object Detail, written to its settings (`prefs.gas`), so its Video page needn't be used |
| Online | the CD key for the internet lobby (only a hash of it is stored; **Remove Key** deletes it); LAN games need none |
| Updates | the newest commit of the app's branch on GitHub; press to rebuild (below) |

**Test Lab** (the Game row): the game in a window beside a panel that travels anywhere in the map, spawns enemies,
gives gear and casts every spell and power, with a record of each test, on copies of your saves (yours are never
changed). See [docs/TEST-LAB.md](docs/TEST-LAB.md).

The first time you host or look for a multiplayer game, macOS asks whether Dungeon Siege II may find devices on your
local network, and the firewall (if it is on) whether it may accept incoming connections. Allow both. **Cmd+Q** quits
the game.

## Updating

**From the app:** the launch window's **Updates** row asks GitHub for the newest commit of the app's branch: `main` for
*Dungeon Siege II*, `nightly` for *Dungeon Siege II Nightly*. When it says **Update available**, press it. The new
version is checked out into `build/stable` (or `build/nightly`) inside your clone, the app is rebuilt from your copy of
the game (about 10 minutes, with a progress window), and it restarts. Your own checkout, game folder, saves, settings
and CD key are left as they are. The output goes to `update.log` in the data folder.

This needs the clone the app was installed from, still in the same place; otherwise the row says *Not available*.
*Couldn't check* means GitHub wasn't reachable (`git fetch` in the clone has to work); press it to retry.

**Known limitation:** the updater runs the new `install.sh` without the options you first installed with. If you used
`--app-dir` or `--data-dir`, update by hand instead: with a custom `--app-dir` the update can't find the installed app
and stops, and with a custom `--data-dir` the rebuilt app would use the default data folder.

**By hand:** `git pull`, then run `./install.sh` again (with the same `--app-dir`/`--data-dir`, if any; the game
folder is remembered).

**Stable and Nightly.** New work lands on the `nightly` branch first and reaches `main` once it has proven itself.
`./install.sh --nightly` builds the newest `nightly` in `build/nightly` (your checkout stays as it is) and installs
**Dungeon Siege II Nightly.app** next to the stable app, with its own icon. Both share the data folder (saves and
settings); each keeps its own log. Run it again, or use its Updates row, to update it.

## Uninstalling

Delete `~/Applications/Dungeon Siege II Native.app` (and `Dungeon Siege II Nightly.app`), the cloned folder, and
`~/Games/DungeonSiege2Native` if you no longer want your saves. Your game folder was never changed.

## Multiplayer

The GOG release ships with the Multiplayer button switched off, and GameSpy, the service the game was built on, closed
in 2014. This port switches it back on and points the game at [OpenSpy](https://openspy.net), the community-run
replacement. Dungeon Siege II goes through a lobby for every kind of game.

- **LAN:** Local Network → the LAN lobby → host or join, Ready, Start, and everyone plays in the same world. No CD key
  and no internet connection needed (the lobby runs on the players' own machines). Multiplayer parties are kept apart
  from single-player saves. Tested with two copies on one Mac; not yet between two Macs or with a PC.
- **Internet:** signs in to OpenSpy and shows the game list, parties and chat rooms. It needs the CD key of an
  original retail copy: the Steam and GOG releases come without one, and this port doesn't work around the key check.
  Hosting and joining over the internet are not tested.

Details, the CD key, PC players and settings: [docs/MULTIPLAYER.md](docs/MULTIPLAYER.md).

## Known issues

- Multiplayer: see the testing limits above. After leaving the lobby for a single-player game, the lobby's Party
  Selection window stays drawn over the top left of the screen. The intro movie plays on every machine when a game
  starts (Esc skips it). Two copies on one Mac show red connection bars in the staging area.
- Of the shader effects, the water and the glow are seen in play; heat shimmer, shadow blur, ice, specular and Dot3
  lighting are checked by render tests only. Distant water looks hazy with shaders on; that comes from the game's own
  water shader, which fogs by distance.
- Around the Notch uses a borderless window rather than macOS full screen.
- C++ exception catch continuations aren't implemented (the game hasn't needed them).
- Not supported: the Broken World expansion, the Steam and retail releases, controllers.

Open issues: [github.com/Joshspeakman/dungeon-siege-2-macos/issues](https://github.com/Joshspeakman/dungeon-siege-2-macos/issues).

## Troubleshooting

- **"... is not the GOG Dungeon Siege II 2.3 release"** (or "not the original GOG 2.3 DungeonSiege2.exe"): the folder
  holds another version of the game (Steam, disc, another patch level, or a modified executable).
- **"no DungeonSiege2.exe in ..."**: give `--game-dir` the folder that holds `DungeonSiege2.exe`.
- **"clang is missing" or "python3 is missing":** run `xcode-select --install`.
- **"innoextract is needed for --gog-installer":** `brew install innoextract`.
- **"the native build is for Apple Silicon Macs":** the build needs an M-series Mac.
- **"Could not find a valid CDKey"** in the internet lobby: store your retail key in the launch window's Online row, or
  with `./install.sh --cd-key`. LAN games don't need one.
- **A crash or freeze:** the app writes a report to `~/Games/DungeonSiege2Native/CrashReports` and offers it on the
  next launch. Attach it, and the log (`~/Games/DungeonSiege2Native/DungeonSiege2Native.log`), when reporting a
  problem.
- **An update fails:** read `update.log` in the data folder; updating by hand (`git pull`, then `./install.sh`) always
  works.

## Tests

The game itself has been checked by playing (menus, hero creation, movies, the opening of the campaign, save/load,
spells and powers in the Test Lab, LAN games) and a 6-minute random-input soak. Tools in `recomp/tests`:

- `fx_render_test.m`: renders each of the game's pixel shaders, as the port compiles them, with known inputs and
  checks what they compute (156 checks; needs the `.fx` files extracted from your copy); `hlsl_check.m` compiles
  every effect pass to Metal;
- `dp8test.c` and `dp8fuzz.c`: the DirectPlay 8 transport against Microsoft's protocol examples, a loopback session
  with packet loss, and hostile input;
- `test_lab_test.py`: the Test Lab's archive, parser and protocol code, without game files;
- `renderer_init_test.m`, `frame_trace_test.c`: Metal buffer source bounds and safe frame-trace shutdown, with
  memory/thread sanitizers; `frame_wait_test.c` measures the capped-frame wait's CPU cost and deadline lateness;
- `runtime_regressions.sh`: no-game macOS sanitizer checks for critical-section collision/deletion/reuse and
  oversized Metal uploads, draw reservations, GPU copies and buffer wrapping;
- `harness.py`, `fuzz_insn.py`, `test_slice.py`, `startup.py`: the recompiler checked instruction by instruction
  against the original x86 in Unicorn (from the Dungeon Siege 1 port);
- `audiocheck.c`, `undname_test.c`, `tracediff.py`: recorded audio against a reference, symbol demangling, traces.

## How it works

`recomp/` holds the recompiler (x86 → C, then clang) and the runtime: a macOS implementation of the Windows APIs the
game uses, Direct3D 9 and D3DX (with an HLSL-to-Metal compiler for the effects) on the Metal renderer in `src/`,
DirectPlay 8 and Winsock, and Miles audio and Bink video (both recompiled from the DLLs in your game folder). Everything
generated from the game stays in `recomp/work/` and is never committed. Details in [recomp/README.md](recomp/README.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/MULTIPLAYER.md](docs/MULTIPLAYER.md) | LAN and internet games, the CD key, PC players, settings, privacy |
| [docs/TEST-LAB.md](docs/TEST-LAB.md) | The Test Lab |
| [recomp/README.md](recomp/README.md) | How the recompiler works, verification, developer switches |
| [docs/PLAN.md](docs/PLAN.md) | Open work and the original bring-up plan |

## Legal

This project contains no game code, data or assets. The game's executable is recompiled on your own Mac from your own
legally obtained copy, and the app reads the game's data from that copy at run time. It does not remove copy
protection or work around the CD-key check. Dungeon Siege II is a trademark of its respective owners; this project is
not affiliated with them. The project's own code is MIT-licensed ([LICENSE](LICENSE)); credits are in
[NOTICE.md](NOTICE.md).
