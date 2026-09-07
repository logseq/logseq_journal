#!/usr/bin/env python3
"""Independently check the literal UTF-16 checksum tuples in vectors.json."""
import json
from pathlib import Path

vectors = json.loads(Path(__file__).with_name('vectors.json').read_text())
for name, vector in vectors.items():
    sums = [0, 0]
    for entity, attribute, value in vector['tuples']:
        data = '\x1f'.join((entity, ':' + attribute, value)).encode('utf-16-le')
        units = [int.from_bytes(data[i:i+2], 'little') for i in range(0, len(data), 2)]
        fnv = 2166136261
        for unit in units:
            fnv = ((fnv ^ unit) * 16777619) % 2**32
        # Polynomial form independently checks the iterative DJB recurrence.
        djb = (5381 * pow(33, len(units), 2**32) + sum(
            unit * pow(33, len(units) - i - 1, 2**32)
            for i, unit in enumerate(units))) % 2**32
        sums[0] += fnv
        sums[1] += djb
    digest = ''.join(f'{value % 2**32:08x}' for value in sums)
    assert digest == vector['digest'], (name, digest)
    print(name, digest)
