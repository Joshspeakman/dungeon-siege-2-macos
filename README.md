# Dungeon Siege II for Apple Silicon Macs

Dungeon Siege II (GOG release 2.3), statically recompiled from your own copy into native arm64 code and run on Metal,
as [dungeon-siege-macos](https://github.com/Joshspeakman/dungeon-siege-macos) does for Dungeon Siege 1. No Wine, no
Rosetta, no emulator. Nothing from the game is in this repository: the build regenerates everything locally from your
copy, and the game folder is only read.

**State: Beta 1, with fixes since.** Single player is playable:

- the main menu, hero creation, the intro movie and opening cutscene;
- gameplay: the world, characters, the HUD, dialogue, combat, spells and powers; saving and loading;
- the display's own resolution, up to 120 fps (Game Mode, real macOS full screen), with a larger interface on
  high-resolution displays if wanted;
- the game's shader effects (Options → Video → Shaders), translated from its HLSL to Metal: water with refraction and
  reflection and the glow are seen in play; heat shimmer, shadow blur, ice, specular and Dot3 lighting are checked by
  render tests (no save reaches them yet);
- a View Distance setting that pushes out each area's fog, like the SeeFar mods;
- sound (Miles) and movies (Bink), recompiled from the DLLs in your game folder;
- multiplayer switched back on (the GOG release disables it): LAN games (host, join, play together) with no CD key and
  no online service; the internet lobby signs in to OpenSpy with an original retail CD key.

What's next: [docs/PLAN.md](docs/PLAN.md).

## Install

Needs an Apple Silicon Mac, the Xcode command line tools (`xcode-select --install`) and python3.

```sh
git clone <this repository> && cd dungeon-siege-2-macos
./install.sh --gog-installer ~/Downloads/setup_dungeon_siege_2_*.exe   # GOG offline installer (brew install innoextract)
# or, with the game already unpacked or installed somewhere:
./install.sh --game-dir "/path/to/Dungeon Siege 2"
./install.sh --nightly                                                 # also "Dungeon Siege II Nightly" (the nightly branch)
```

This recompiles the game (a few minutes) and installs **Dungeon Siege II Native** in `~/Applications`. Settings, saves
and logs live in `~/Games/DungeonSiege2Native`.

## The launch window

Laid out like the Dungeon Siege 1 port's: the game's key art, the Game row, then Display, Graphics, Online and Updates.

| Setting | Choices |
|---|---|
| Game | Play · **Test Lab** (below) |
| Display → Resolution | the display's own resolution (default) and the sizes it supports |
| Display → Interface Size | 100% to 300%: the game runs at the resolution divided by it (a larger interface), and the screen is drawn at the full resolution, so the world stays sharp |
| Display → Frame Rate | **Automatic** (120 fps on a 120 Hz display, 60 in the heaviest scenes) · 120 · 60 · 30 · Unlimited |
| Display → View Distance | **Original** · Far (125%) · Farther (150%, like SeeFar) · Very Far (200%) · Horizon (250%) · Maximum (300%) |
| Display → Gamma, Notch | the game's brightness; on a Mac with a notch, the picture below it or around it |
| Graphics | the game's own Shaders, Shadows, Texture Filtering and Object Detail, written to its settings (prefs.gas), so its Video page needn't be used |
| Online | the CD key for the internet lobby (only a hash of it is stored); LAN games need none |
| Updates | rebuilds the app from the newest commit of its branch, from your own copy of the game |

**Test Lab** (the launch window's Game row): the game in a window beside a panel that travels anywhere in the
map, spawns enemies, gives gear and casts every spell and power, with a record of each test, on copies of your saves.
From the Linux port; see [docs/TEST-LAB.md](docs/TEST-LAB.md).

## Multiplayer

The GOG release ships with the Multiplayer button switched off and GameSpy, the service the game was built on, closed
in 2014. This port switches it back on and points the game at [OpenSpy](https://openspy.net), the community-run
replacement. Dungeon Siege II goes through its lobby for every kind of game.

- **LAN:** Local Network → the LAN lobby → host or join, Ready, Start, and everyone plays in the same world. No CD key
  and no internet connection needed (the lobby runs on the players' own machines). Tested with two copies on one Mac;
  not yet between two Macs or with a PC.
- **Internet:** signs in to OpenSpy and shows the game list, parties and chat rooms. It needs the CD key of an
  original retail copy (the Steam and GOG releases have none); hosting and joining over the internet are not tested.

Details, the CD key and settings: [docs/MULTIPLAYER.md](docs/MULTIPLAYER.md).

## Nightly

`./install.sh --nightly` installs **Dungeon Siege II Nightly** next to the stable app, built from the `nightly` branch
(experimental work, before it reaches `main`), sharing the same saves and settings. Right now `nightly` and `main` are
the same.

## Tests

The game itself has been checked by playing (menus, hero creation, movies, the opening of the campaign, save/load,
spells and powers in the Test Lab) and a 6-minute random-input soak. Tools in `recomp/tests`:

- `fx_render_test.m`: renders each of the game's pixel shaders, as the port compiles them, with known inputs and
  checks what they compute (156 checks; needs the `.fx` files extracted from your copy); `hlsl_check.m` compiles
  every effect pass to Metal;
- `dp8test.c` and `dp8fuzz.c`: the DirectPlay 8 transport against Microsoft's protocol examples, a loopback session
  with packet loss, and hostile input;
- `test_lab_test.py`: the Test Lab's archive, parser and protocol code, without game files;
- `renderer_init_test.m`, `frame_trace_test.c`: Metal buffer source bounds and safe frame-trace shutdown, with
  memory/thread sanitizers; `frame_wait_test.c` measures the capped-frame wait's CPU cost and deadline lateness;
- `harness.py`, `fuzz_insn.py`, `test_slice.py`, `startup.py`: the recompiler checked instruction by instruction
  against the original x86 in Unicorn (from the Dungeon Siege 1 port);
- `audiocheck.c`, `undname_test.c`, `tracediff.py`: recorded audio against a reference, symbol demangling, traces.

## How it works

`recomp/` holds the recompiler (x86 → C, then clang) and the runtime: a macOS implementation of the Windows APIs the
game uses, Direct3D 9 and D3DX (with an HLSL-to-Metal compiler for the effects) on the Metal renderer in `src/`,
DirectPlay 8 and Winsock, and Miles audio and Bink video (both recompiled from the DLLs in your game folder). Details
in [recomp/README.md](recomp/README.md).

Known gaps: C++ exception catch continuations aren't implemented (the game hasn't needed them); the Broken World
expansion (a separate executable) isn't supported.

Dungeon Siege II is a trademark of its owners; this project is not affiliated with them. You need your own copy of the
game.
