#!/usr/bin/env python3
"""Check the iPhone 13 synthetic Application's scrolled native Back recording."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def check_native(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
    scrolled = [(row, view) for row in rows for view in row.get('lists', [])
                if view['inset'][0] == 47 and view['offset'] == [0, 646]]
    assert len(scrolled) >= 30, 'Required public drag did not reach offset 646'
    first, baseline = scrolled[0]
    attached = [view for row in rows if row['time'] >= first['time']
                for view in row.get('lists', []) if view['inset'][0] == 47]
    for view in attached:
        for field in ['id', 'cells', 'offset', 'inset', 'safe', 'content']:
            assert view[field] == baseline[field], f'Timeline changed {field}'
        assert not view['topHidden'], 'Top glass was disabled'
    root_node = next(row['node'] for row in rows if row['kind'] == 'list-body')
    assert not any(row['kind'] == 'list-body' and row['node'] == root_node
                   and row['time'] > first['time'] for row in rows), 'Timeline List body reran'
    return {'root': baseline, 'attachedSamples': len(attached), 'rootNode': root_node}


def check_video(path):
    pts = subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
        'frame=best_effort_timestamp_time', '-of', 'csv=p=0', path], text=True)
    times = [float(line.split(',')[0]) for line in pts.splitlines() if line.strip()]
    process = subprocess.Popen([
        'ffmpeg', '-v', 'error', '-i', path, '-vf', 'scale=390:844',
        '-fps_mode', 'passthrough', '-enc_time_base', '1:600',
        '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL)
    stable = []
    body_pattern = None
    for index, timestamp in enumerate(times):
        pixels = process.stdout.read(390 * 844)
        assert len(pixels) == 390 * 844, 'Decoded frame count differs from PTS'
        def dark(y, height):
            return sum(value < 100 for row in range(y, y + height)
                       for value in pixels[row * 390 + 28:row * 390 + 273])
        # The normal-area child 11 glyphs fingerprint the fully visible root.
        middle = dark(155, 22)
        body_pattern = bytes(value < 100 for row in range(155, 177)
                             for value in pixels[row * 390 + 28:row * 390 + 273])
        if 655 <= middle <= 659:
            stable.append({'frame': index + 1, 'pts': timestamp,
                           'topDark': dark(45, 14), 'middleDark': middle, '_bodyPattern': body_pattern})
    assert process.wait() == 0, 'Video decoding failed'
    assert body_pattern is not None and 655 <= sum(body_pattern) <= 659, 'Recording must end on the scrolled fixture root'
    # Counts alone can coincide during native snapshot scaling. Require the
    # same normal-area glyph positions, allowing a few compression edge pixels.
    stable = [frame for frame in stable
              if sum(a != b for a, b in zip(frame.pop('_bodyPattern'), body_pattern)) <= 12]
    assert len(stable) >= 50, 'Insufficient fully-visible scrolled root frames'
    assert any(frame['topDark'] < 80 for frame in stable), 'No retained top blur observed'
    sharp = [frame for frame in stable if frame['topDark'] > 180]
    return {'stableRootFrames': len(stable), 'sharpFrames': sharp,
            'topDarkMaximum': max(frame['topDark'] for frame in stable)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', required=True)
    parser.add_argument('--trace', required=True)
    parser.add_argument('--output')
    parser.add_argument('--expect-flash', action='store_true',
                        help='Verify the RED original/soft control reproduces')
    args = parser.parse_args()
    result = {'native': check_native(args.trace), 'visual': check_video(args.video)}
    result['passed'] = bool(result['visual']['sharpFrames']) == args.expect_flash
    if args.output:
        Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'root': result['native']['root']['id'],
                      'offset': result['native']['root']['offset'],
                      'stableRootFrames': result['visual']['stableRootFrames'],
                      'sharpFrames': len(result['visual']['sharpFrames']),
                      'topDarkMaximum': result['visual']['topDarkMaximum']}))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
