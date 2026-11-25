#!/usr/bin/env python3
"""The launch window's art for Dungeon Siege II, made from the player's own copy (and the store's, with --store).

    ds2_art.py <game folder> <art folder> [--store]

From the copy: frames of the game's own cutscenes (the Bink movies in Resources/Movies1.ds2res and Movies2.ds2res,
decoded with ffmpeg when it is installed), each without its letterbox and sharpened for the window:
    scene-<n>.jpg     the backdrop's slides (the prologue's paintings, Aranna, the dragons, the Valdis fights)
    portrait.jpg      a warrior of the elftown fight, for the framed portrait (offline)
    card-game.jpg     the Game card's picture; card-lab.jpg the Test Lab card's
With --store (skipped when offline): Steam's art for the game (app 39200)
    store-portrait.jpg  the library capsule (the heroes, 600x900): the framed portrait
    store-hero.jpg      the library hero (the key art, wide): a slide that pans
    store-shot-<n>.jpg  the store page's screenshots: slides
    store-logo.png      the library logo
A file that is there already is kept. Nothing from the game is stored in the project: this runs on the player's Mac
(install.sh). The window falls back to the game's own main-menu art (read from Objects.ds2res) without any of it.
"""
import os, shutil, struct, subprocess, sys, tempfile, urllib.request, zlib, mmap

# (movie, where in it: seconds, or a fraction of its length) -> scene-<n>.jpg in this order
SCENES = [("a0_prologue_part1", 30.0), ("a0_tutorial_intro", 4 / 7), ("a1_valdis_rustguards", 6 / 7),
          ("a2_sacred_isles_intro", 2 / 7), ("a0_prologue_part2", 1 / 7), ("a2_elftown_destruction", 2 / 7),
          ("a0_tutorial_intro", 6 / 7), ("a0_prologue_part1", 50.0), ("a1_valdis_rustguards", 2 / 7),
          ("a0_prologue_part2", 3 / 7), ("a0_tutorial_intro", 2 / 7), ("a2_sacred_isles_intro", 6 / 7)]
PORTRAIT = ("a2_elftown_destruction", 3 / 7)
CARDS = {"card-game.jpg": ("a2_elftown_destruction", 2 / 7), "card-lab.jpg": ("a3_waterworks_flythrough_cap", 4 / 7)}
STEAM = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/39200/"
STORE = {"store-portrait.jpg": STEAM + "library_600x900_2x.jpg", "store-hero.jpg": STEAM + "library_hero.jpg",
         "store-logo.png": STEAM + "logo.png",
         "store-shot-1.jpg": STEAM + "ss_d37862b6d7553247dd3f14316a08832db02eabc5.1920x1080.jpg",
         "store-shot-2.jpg": STEAM + "ss_789bca4294a6dd6b9ccdf7ba57bd89687ea244e4.1920x1080.jpg",
         "store-shot-3.jpg": STEAM + "ss_3b738ee0742be358783d35c01edc11bde9aa9212.1920x1080.jpg"}


def tank_files(path):
    """the files of a tank archive (.ds2res): {lower-case path: (reader)}"""
    f = open(path, "rb"); d = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    if d[:8] not in (b"DSigTank", b"DSg2Tank"): return {}
    u32 = lambda o: struct.unpack_from("<I", d, o)[0]; u16 = lambda o: struct.unpack_from("<H", d, o)[0]
    dirset, fileset, dataoff = u32(12), u32(16), u32(24)
    dirs, parents = {}, {}
    for k in range(u32(dirset)):
        off = u32(dirset + 4 + 4 * k); o = dirset + off; n = u16(o + 16)
        dirs[off] = d[o + 18:o + 18 + n].decode("latin1"); parents[off] = u32(o)

    def path(off):
        parts = []
        for _ in range(64):
            if not dirs.get(off): break
            parts.insert(0, dirs[off]); p = parents[off]
            if p == off: break
            off = p
        return "/".join(parts)

    out = {}
    for k in range(u32(fileset)):
        o = fileset + u32(fileset + 4 + 4 * k); parent, size, foff = u32(o), u32(o + 4), u32(o + 8); fmt, n = u16(o + 24), u16(o + 28)
        name = path(parent) + "/" + d[o + 30:o + 30 + n].decode("latin1")

        def read(o=o, n=n, size=size, foff=foff, fmt=fmt):
            if fmt == 0: return bytes(d[dataoff + foff:dataoff + foff + size])
            o2 = (o + 30 + n + 1 + 3) & ~3; chunk = u32(o2 + 4); o2 += 8; buf = bytearray()
            for c in range((size + chunk - 1) // chunk):
                usz, csz, extra, coff = struct.unpack_from("<IIII", d, o2 + 16 * c); src = dataoff + foff + coff
                buf += zlib.decompress(d[src:src + csz]) if csz < usz else d[src:src + usz]
                if extra: buf += d[src + csz:src + csz + extra]
            return bytes(buf[:size])
        out[name.lower()] = read
    return out


def find_ci(folder, name):
    for n in os.listdir(folder) if os.path.isdir(folder) else []:
        if n.lower() == name.lower(): return os.path.join(folder, n)
    return None


def frame(ffmpeg, movie, at, out, crop=None, size="1600:900"):
    """one frame of a movie (at: seconds, or a fraction of its length), its letterbox cut off, scaled and sharpened"""
    if at < 1:
        p = subprocess.run([ffmpeg.replace("ffmpeg", "ffprobe"), "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", movie],
                           capture_output=True, text=True)
        try: at = float(p.stdout.strip()) * at
        except ValueError: return False
    vf = (crop or "crop=iw:ih*0.75:0:ih*0.125") + f",scale={size}:flags=lanczos,unsharp=5:5:0.6"
    r = subprocess.run([ffmpeg, "-v", "error", "-y", "-ss", f"{at:.2f}", "-i", movie, "-frames:v", "1", "-vf", vf, "-q:v", "2", out + ".part.jpg"],
                       capture_output=True)
    if r.returncode or not os.path.exists(out + ".part.jpg") or os.path.getsize(out + ".part.jpg") < 20000:
        if os.path.exists(out + ".part.jpg"): os.remove(out + ".part.jpg")
        return False
    os.replace(out + ".part.jpg", out); return True


def from_copy(game, art):
    ffmpeg = shutil.which("ffmpeg") or next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if os.path.exists(p)), None)
    res = find_ci(game, "Resources")
    if not ffmpeg or not res: return
    movies = {}
    for t in ("Movies1.ds2res", "Movies2.ds2res"):
        p = find_ci(res, t)
        if p: movies.update(tank_files(p))
    want = [(f"scene-{k + 1}.jpg", m, at, None, "1600:900") for k, (m, at) in enumerate(SCENES)]
    want.append(("portrait.jpg", PORTRAIT[0], PORTRAIT[1], "crop=ih*0.75*0.75:ih*0.75:iw*0.36:ih*0.125", "600:800"))
    want += [(n, m, at, None, "800:450") for n, (m, at) in CARDS.items()]
    tmp = tempfile.mkdtemp(prefix="ds2art.")
    try:
        got = {}
        for name, m, at, crop, size in want:
            out = os.path.join(art, name)
            if os.path.exists(out): continue
            read = movies.get(f"movies/{m}.bik")
            if not read: continue
            if m not in got:
                got[m] = os.path.join(tmp, m + ".bik")
                with open(got[m], "wb") as f: f.write(read())
            frame(ffmpeg, got[m], at, out, crop, size)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def from_store(art):
    for name, url in STORE.items():
        out = os.path.join(art, name)
        if os.path.exists(out): continue
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"}), timeout=20) as r:
                data = r.read()
        except Exception:
            continue
        if len(data) < 20000 or not (data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n"): continue
        with open(out + ".part", "wb") as f: f.write(data)
        os.replace(out + ".part", out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2: sys.exit(__doc__)
    game, art = args[0], args[1]
    os.makedirs(art, exist_ok=True)
    if game != "-": from_copy(game, art)
    if "--store" in sys.argv: from_store(art)


if __name__ == "__main__":
    main()
