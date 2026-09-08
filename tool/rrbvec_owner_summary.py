#!/usr/bin/env python3
"""Summarize retained-state owner samples, keeping absolute values and dispersion."""
import hashlib
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / 'docs/test-reports/2026-09-07-rrbvec'


def read(path):
    groups, live = {}, []
    for line in path.read_text().splitlines():
        if line.startswith('PROBE '):
            _, name, value = line.split(' ', 2)
            operation, sample = name.rsplit('-', 1)
            if sample == '1':
                continue
            groups.setdefault(operation, []).append(json.loads(value))
        elif line.startswith('LIVE '):
            _, name, words = line.split()
            live.append({'phase': name, 'bytes': int(words) * 8})
    return groups, live


def distribution(values):
    return {'median': statistics.median(values), 'min': min(values), 'max': max(values),
            'stdev': statistics.stdev(values) if len(values) > 1 else 0, 'samples': values}


def summarize(samples):
    return {'time_us': distribution([s['elapsed_ns'] / s['iterations'] / 1000 for s in samples]),
            'allocated_bytes': distribution([s['allocated_words'] * 8 / s['iterations'] for s in samples]),
            'minor_collections': distribution([s['minor_collections'] for s in samples]),
            'major_collections': distribution([s['major_collections'] for s in samples]),
            'checksums': [s['checksum'] for s in samples]}


def main():
    comparisons = []
    for path in sorted(REPORT.glob('*-list.log')):
        if path.name.startswith('buckets-'):
            continue
        vector = path.with_name(path.name.replace('-list.log', '-vector.log'))
        variants = [('combined', vector)]
        if path.name.startswith('worker-'):
            variants.append(('worker-only', path.with_name(path.name.replace('-list.log', '-isolated-vector.log'))))
        for variant, other in variants:
            assert 'OWNER_PROBE_PASSED' in path.read_text(), path
            assert 'OWNER_PROBE_PASSED' in other.read_text(), other
            before, before_live = read(path)
            after, after_live = read(other)
            rows = []
            for operation, samples in before.items():
                assert len(samples) == len(after[operation]) == 6
                old, new = summarize(samples), summarize(after[operation])
                assert old['checksums'] == new['checksums'], (path, operation)
                rows.append({'operation': operation, 'list': old, 'vector': new,
                             'time_ratio': new['time_us']['median'] / old['time_us']['median'],
                             'allocation_ratio': new['allocated_bytes']['median'] / old['allocated_bytes']['median']})
            comparisons.append({'workload': path.stem.removesuffix('-list'), 'variant': variant,
                                'list_log': path.name, 'vector_log': other.name, 'operations': rows,
                                'list_live_memory': before_live, 'vector_live_memory': after_live})
    files = ['app/journal_timeline_state.ml', 'app/journal_timeline_state.mli', 'app/journal_timeline.ml',
             'app/application.ml', 'logseq_db_worker/lib/effect_runner/effect_runner.ml',
             'logseq_overlay_db/lib/database.ml']
    result = {'baseline_commit': 'b32baf08ef0503cc84ab5df613607b058efa9e59',
              'rrbvec_commit': 'dd5ce904f91d53235b5136f7a771f3f074c3971d',
              'word_bytes': 8, 'discarded_samples': [1],
              'implementation_sha256': {f: hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files},
              'comparisons': comparisons}
    (REPORT/'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    lines = ['# Owner measurements', '',
             'Each row reports the median of six native samples after discarding the first sample. Time is microseconds per operation; brackets show the observed minimum and maximum. Allocation is bytes per operation on arm64. Ratios are vector / List.', '']
    for comparison in comparisons:
        lines += [f"## {comparison['workload']} ({comparison['variant']})", '',
                  f"Raw samples: [{comparison['list_log']}]({comparison['list_log']}), [{comparison['vector_log']}]({comparison['vector_log']}).", '',
                  '| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |',
                  '| --- | --- | --- | --- | --- | --- | --- |']
        for row in comparison['operations']:
            a, b = row['list']['time_us'], row['vector']['time_us']
            lines.append(f"| {row['operation']} | {a['median']:.3f} [{a['min']:.3f}, {a['max']:.3f}] | {b['median']:.3f} [{b['min']:.3f}, {b['max']:.3f}] | {row['time_ratio']:.3f} | {row['list']['allocated_bytes']['median']:.0f} | {row['vector']['allocated_bytes']['median']:.0f} | {row['allocation_ratio']:.3f} |")
        lines.append('')
    (REPORT/'measurements.md').write_text('\n'.join(lines))
    print(f'Wrote {len(comparisons)} comparisons with matching checksums.')


if __name__ == '__main__':
    main()
