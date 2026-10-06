#!/usr/bin/env python3
"""Compile Dakshina v1.0 hi/pa/ur lexicons into sorted memory-mapped tables.

Input: directory containing *.translit.sampled.{train,dev,test}.tsv files.
Data remains CC BY-SA 4.0; see Resources/Romanization/README.md.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import struct
import unicodedata


def normalize(word, language):
    word = unicodedata.normalize('NFKC', word).replace('\u200c', '').replace('\u200d', '')
    if language == 'ur':
        word = ''.join(c for c in word if c != '\u0640' and unicodedata.category(c) != 'Mn')
        word = word.translate(str.maketrans({'ك': 'ک', 'ي': 'ی', 'ى': 'ی', 'ه': 'ہ'}))
    return unicodedata.normalize('NFC', word)


def compile_lexicons(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    manifest = {'dataset': 'Dakshina v1.0', 'license': 'CC-BY-SA-4.0', 'languages': {}}
    for language in ('hi', 'pa', 'ur'):
        entries = defaultdict(Counter)
        inputs = {}
        for split in ('train', 'dev', 'test'):
            path = source / f'{language}.translit.sampled.{split}.tsv'
            data = path.read_bytes()
            inputs[path.name] = hashlib.sha256(data).hexdigest()
            for line in data.decode().splitlines():
                native, roman, votes = line.split('\t')
                native = normalize(native, language)
                roman = roman.lower()
                # A lexicon entry is a source word, never a translated phrase.
                if not native or any(c.isspace() for c in native) or not re.fullmatch("[a-z][a-z']*", roman):
                    continue
                entries[native][roman] += int(votes)
        records = []
        for native, variants in sorted(entries.items(), key=lambda item: item[0].encode()):
            # Prefer the most attested form, then avoid vowel-free abbreviation.
            roman = min(variants, key=lambda r: (-variants[r], not any(c in 'aeiou' for c in r), len(r), r))
            records.append(native.encode() + b'\0' + roman.encode() + b'\0')
        offsets = [0]
        for record in records:
            offsets.append(offsets[-1] + len(record))
        payload = b'BNRL0001' + struct.pack('<I', len(records))
        payload += struct.pack(f'<{len(offsets)}I', *offsets) + b''.join(records)
        (destination / f'{language}.lexicon').write_bytes(payload)
        manifest['languages'][language] = {'entries': len(records), 'bytes': len(payload),
                                          'sha256': hashlib.sha256(payload).hexdigest(), 'inputs': inputs}
        print(language, len(records), len(payload))
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path('boringNotch/Resources/Romanization'))
    args = parser.parse_args()
    compile_lexicons(args.source, args.output)
