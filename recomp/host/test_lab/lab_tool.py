#!/usr/bin/env python3
"""The Test Lab's helper on macOS (the Linux port's lab_content.py and lab_commands.py, used unchanged).

The Test Lab window (host/test_lab.m) runs:
  lab_tool.py catalog <game folder>          the content catalog as JSON (read from your own archives)
  lab_tool.py skrit                          stdin {"action", "entry", "options"} -> the request's Skrit on stdout
and it can be used from a terminal while a test game runs (`<data>` is the lab's data folder, ~/Games/DungeonSiege2Native/test-lab):
  lab_tool.py copy-saves <normal data> <lab data>
  lab_tool.py send <lab data> <action> [<group> <id>] [key=value ...]   one request; waits for the reply
  lab_tool.py find <game folder> <group> <words...>                      catalog entries matching words
Every request and reply is recorded in <lab data>/lab/history.jsonl, as on Linux.
"""
import json
from pathlib import Path
import shutil
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lab_commands import Bridge, command
from lab_content import build_catalog

BACKEND = 'macos-metal'
SAVE_RELATIVE = Path('drive_c/Users/player/Documents/My Games/Dungeon Siege 2/Save/SinglePlayer')


def copy_saves(source, destination):
    """Fresh copies of the single-player saves; earlier lab saves go to save-backups/ (the originals are never touched)."""
    src, dst = Path(source) / SAVE_RELATIVE, Path(destination) / SAVE_RELATIVE
    if dst.exists():
        backup = Path(destination) / 'save-backups' / str(time.time_ns())
        backup.parent.mkdir(parents=True, exist_ok=True)
        dst.rename(backup)
    if src.is_dir():
        shutil.copytree(src, dst, symlinks=False)
    else:
        dst.mkdir(parents=True, exist_ok=True)


class MacBridge(Bridge):
    def record(self, record):
        if record.get('backend') == 'linux-fixed-function':
            record = dict(record, backend=BACKEND)
        super().record(record)


def entry_for(game, group, ident):
    for entry in build_catalog(game)[group]:
        if entry['id'] == ident:
            return entry
    raise SystemExit(f'no {group} entry {ident}')


def value(text):
    for convert in (int, float):
        try:
            return convert(text)
        except ValueError:
            pass
    return {'true': True, 'false': False}.get(text, text)


def main(argv):
    if len(argv) >= 2 and argv[0] == 'catalog':
        json.dump(build_catalog(argv[1]), sys.stdout); return 0
    if argv[:1] == ['skrit']:
        request = json.load(sys.stdin)
        try:
            sys.stdout.write(command(request['action'], request.get('entry'), **request.get('options', {})))
        except (ValueError, KeyError) as e:
            sys.stdout.write('ERROR: ' + str(e)); return 1
        return 0
    if len(argv) == 3 and argv[0] == 'copy-saves':
        copy_saves(argv[1], argv[2]); return 0
    if len(argv) >= 3 and argv[0] == 'find':
        words = [w.lower() for w in argv[3:]]
        for entry in build_catalog(argv[1])[argv[2]]:
            if all(w in json.dumps(entry).lower() for w in words):
                print(entry['id'], '|', entry['label'])
        return 0
    if len(argv) >= 3 and argv[0] == 'send':
        data, action, rest = argv[1], argv[2], argv[3:]
        entry = None
        if len(rest) >= 2 and '=' not in rest[0]:
            game = Path(data).parent / 'game'
            import os
            game = os.environ.get('DS_GAME_DIR', str(game))
            entry = entry_for(game, rest[0], rest[1]); rest = rest[2:]
        options = dict((k, value(v)) for k, v in (r.split('=', 1) for r in rest))
        bridge = MacBridge(data)
        bridge.send(action, entry, **options)
        while True:
            result = bridge.poll()
            if result:
                print(result['status'], '|', result.get('message', '')); return 0 if result['status'] == 'ok' else 1
            time.sleep(0.1)
    print(__doc__); return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
