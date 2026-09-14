#!/usr/bin/env python3
"""Render the ascender.ansible.com CRDs from the awx.ansible.com ones.

The two groups describe the same four resources, and a CRD belongs to exactly
one group, so there is no way to serve both from one file. Keeping two copies by
hand is the arrangement that drifts: three thousand lines of schema, edited on
one side, silently different on the other, and the symptom is a field that
validates under one kind and not the other.

So one side is generated. `make crds` writes the ascender files from the awx
ones and CI fails if the result differs from what is committed, which is the
same shape as the generated API types check.

The transform is two string replacements, and the reason that is safe is worth
stating: the CRDs contain no schema property whose name mentions AWX. Every
occurrence is the group, a kind, a plural, a singular, or prose. Adding a
property called `awx_something` would break that, and the check below fails
loudly rather than renaming a field out from under a user.
"""

import pathlib
import re
import sys

CONFIG = pathlib.Path(__file__).resolve().parent.parent / 'config'
BASES = CONFIG / 'crd' / 'bases'
SAMPLES = CONFIG / 'samples'
SOURCE_GROUP = 'awx.ansible.com'
TARGET_GROUP = 'ascender.ansible.com'

# A property name anywhere in the schema would be renamed by the transform, so
# refuse rather than do it.
PROPERTY_NAMING_AWX = re.compile(r'^\s+[aA][wW][xX][\w]*:\s*$', re.M)


def render(source: str) -> str:
    return source.replace('AWX', 'Ascender').replace('awx', 'ascender')


def main() -> int:
    sources = sorted(BASES.glob(f'{SOURCE_GROUP}_*.yaml'))
    if not sources:
        print(f'no {SOURCE_GROUP} CRDs under {BASES}', file=sys.stderr)
        return 1

    for source in sources:
        text = source.read_text()
        offender = PROPERTY_NAMING_AWX.search(text)
        if offender:
            print(f'{source.name} has a schema property named {offender.group().strip()}, which this cannot rename', file=sys.stderr)
            return 1
        target = BASES / render(source.name)
        target.write_text(render(text))
        print(f'{source.name} -> {target.name}')

    # The sample CRs go the same way, for the same reason: two copies edited by
    # hand end up describing different things.
    for source in sorted(SAMPLES.glob('awx_v1*.yaml')):
        target = SAMPLES / render(source.name)
        target.write_text(render(source.read_text()))
        print(f'{source.name} -> {target.name}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
