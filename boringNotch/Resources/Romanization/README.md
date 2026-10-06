# Human-attested lyric romanization

These three lookup tables are derived from the Hindi, Punjabi, and Urdu
lexicons in the Dakshina dataset v1.0 (released May 27, 2020), published by
Google Research. Each dataset entry records a native spelling, a romanization
provided by human annotators, and the number of attestations.

Authors: Brian Roark, Lawrence Wolf-Sonkin, Christo Kirov, Sabrina J. Mielke,
Cibu Johny, Işın Demirşahin, and Keith Hall.

Source: https://github.com/google-research-datasets/dakshina
Paper: https://aclanthology.org/2020.lrec-1.294/
Archive: https://storage.googleapis.com/gresearch/dakshina/dakshina_dataset_v1.0.tar

The derived lookup data is licensed under **CC BY-SA 4.0**:
https://creativecommons.org/licenses/by-sa/4.0/
This license applies to these data files, independently of the application code.

Changes: combine train/dev/test lexicons; normalize equivalent Unicode spellings
and optional Urdu vowel marks; lowercase Latin output; exclude phrase entries;
choose the most attested spelling with deterministic ties. The manifest records
input/output SHA-256 digests and entry counts. Romanization varies by dialect
and context; these tables do not guarantee every unknown word's pronunciation.

Rebuild with `python3 Scripts/build_romanization_lexicons.py <lexicon-directory>`.
The directory must contain the nine original hi/pa/ur train/dev/test TSV files.

Binary format: ASCII `BNRL0001`, little-endian UInt32 record count, count+1
little-endian UInt32 offsets relative to the payload, then UTF-8 native spelling,
NUL, ASCII romanization, NUL per record. Records sort by native UTF-8 bytes.
Runtime maps the file and binary-searches records, caching converted text;
it does not build a full dictionary or run inference during animation.
