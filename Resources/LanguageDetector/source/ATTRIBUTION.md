# Attribution and provenance

Resource version: `2`

The release lexicon contains 98,574 unique alphabetic word forms: 49,644
English and 48,930 Russian forms retained from FrequencyWords' top-50,000
lists, plus `клавиатура` from the original version 1 fixture. The signed copy
is `Sources/SwitcherCore/Resources/LanguageDetector/v2-word-ranks.tsv`. The
frequency lists are pinned to commit
`525f9b560de45753a5ea01069454e72e9aa541c6` of
<https://github.com/hermitdave/FrequencyWords>, files
`content/2016/en/en_50k.txt` and `content/2016/ru/ru_50k.txt`.

FrequencyWords publishes generated word-list data under CC BY-SA 4.0. The
derived `v2-word-ranks.tsv` remains under that licence and is distributed with
this attribution. The original version 1 fixture data remains CC0 under
`LICENSE.md`.

This file is the detector's complete release-time word evidence. The macOS
executable uses no system dictionary, network service or other external source
of words. Adding another source requires documenting its provenance, licence,
resource version and corpus impact here before it is used by the detector.

The application ships only the generated Swift resource in
`Sources/SwitcherCore/Generated/LanguageResourcesV2.swift`; preparation is
reproducible with:

```sh
swift Scripts/prepare-language-resources.swift
```

The script uses only the Swift standard library and validates the source before
rewriting the generated resource.
