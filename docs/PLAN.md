# Plan: Dungeon Siege II on Apple Silicon

Same approach as the Dungeon Siege 1 port: the user's own GOG copy is recompiled from x86 into C at install time,
compiled for arm64 and linked with a macOS implementation of the Windows APIs it uses. Nothing from the game is
committed.

## Status (2026-10-05)

| Step | State |
|---|---|
| Survey of the GOG 2.3 release | done: see `LLM-Decomp-Guides/dungeon-siege-2` |
| Analysis (`recomp/tools/analyze.py`) | 58,856 functions, 88.9% of `.text` (DS1 reached 99.7% after tuning) |
| Lifting (`recomp/tools/lift.py`) | all functions lifted, 0 internal errors; ~1,000 unsupported instructions, almost all SSE2 C-runtime paths a CPU without SSE2 skips, or data decoded as code; `lock cmpxchg` added |
| Multi-image build (`recomp/build.sh`) | the game plus Miles (`mss32.dll`, `msssoft.m3d`, `mssmp3.asi`, `mssdsp.flt`) and Bink: 62,226 functions, compiles and links in about 4 minutes |
| Windows imports | 517 imported; DS1's runtime covered 345, `ds2_imports.c` adds the rest except Direct3D 9/D3DX (stubs) and Winsock |
| Start-up | runs natively through the C runtime start-up, settings, language DLL lookup, up to `Direct3DCreate9`; without Direct3D 9 the game shows its error dialog and exits |

## Next steps

| # | Work | Notes |
|---|---|---|
| 1 | **Direct3D 9 device on the existing Metal renderer** | `IDirect3D9`/`IDirect3DDevice9` and resources (textures, surfaces, vertex/index buffers, vertex declarations), render/sampler/texture-stage states, transforms, fixed-function draws, render targets, `Present`, `Reset`. New producer next to DS1's `ddraw.c`, same command ring. Build from what the game actually calls (log every method first). |
| 2 | **D3DX texture loading** | DDS (DXT1/3/5 map to Metal BC formats), TGA/BMP from memory; `D3DXCreateTexture*`, `D3DXLoadSurfaceFromMemory`. |
| 3 | **Shaders and effects** | 12 effect files (SM 1.1/2.0 HLSL). Start with effects reported unsupported (the game should fall back), then translate. Options: vkd3d-shader (LGPL) at install time, or a small HLSL-subset → MSL translator. |
| 4 | **C++ exceptions** | ~1,400 functions with try blocks: catch continuations in the lifter/runtime (extends DS1's `__except` landing pads). Needed as soon as the game throws in normal play. |
| 5 | Analysis coverage, unresolved jump tables (49) | as in DS1. |
| 6 | Text rendering (GDI glyphs), Winsock, audio check, movies | |
| 7 | Launcher, installer, updater, app bundle (from DS1) | |
| 8 | Multiplayer (LAN / direct IP; GameSpy is gone), performance, hardening | |

## Running a development build

```sh
recomp/build.sh ~/Games/DungeonSiege2/game/DungeonSiege2.exe      # game folder unpacked from the GOG installer (innoextract)
recomp/tools/build_app.sh recomp/work/full
DS_TEST=1 W32_AUDIO_MUTE=1 recomp/work/full/app/DungeonSiegeNative --exe recomp/work/DungeonSiege2.exe \
    --game ~/Games/DungeonSiege2/game --data <scratch data folder>
```
