# Detector corpus results — version 2

Measured by `LanguageDetectorPrecisionTests` against the fixed corpus in
`source/v2-corpus.tsv`, with resource version `2`:

| Category | Cases | Automatic corrections | Result |
| --- | ---: | ---: | --- |
| `mustCorrect` | 7 | 7 | recall: 100% |
| `mustKeep` | 9 | 0 | false corrections: 0 |
| `ambiguous` | 3 | 0 | retained as uncertain |

The decision margin is deliberately code-and-corpus coupled. It is not a user
setting; altering it requires preparing a new resource version and rerunning
this corpus.
