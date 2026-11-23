# Distribution contents

Status: canonical
Scope: the `0.7.0` MoonBit module archive
Last reviewed: 2026-11-23
Source of truth: [`repo-tools/tools/distribution.json`](https://github.com/ZSeanYves/MoonbitHTTP/blob/main/repo-tools/tools/distribution.json)
Enforcement: [`repo-tools/tools/check_distribution.mbtx`](https://github.com/ZSeanYves/MoonbitHTTP/blob/main/repo-tools/tools/check_distribution.mbtx)

The published archive is a user library distribution. It contains the library
packages, generated public interfaces, colocated tests and benchmarks, the
`internal/test_support` packages, and the current user documentation named by the
manifest. This includes the Native TLS revocation fixture generator referenced
only by white-box tests: Moon resolves these imports even during `moon check`,
so their package sources must be present. The generator is not linked into the
production TLS library. Native TLS certificate, private-key and revocation fixtures are
excluded. Tests that require those fixtures must run from the source checkout;
the published archive is not a self-contained copy of the repository test suite.

The archive does not contain repository automation, command examples,
development scripts, historical reports, generated build output, coverage
files, temporary security/performance evidence, zip files, or release evidence.
Those files remain useful to contributors but are not part of the library
contract. A directory called `internal` would not provide this boundary by
itself, so packaging is controlled by the explicit manifest and the matching
`.moonignore` rules.

`moon package --list` is the observed archive inventory. The distribution
checker compares that inventory in both directions with the manifest, verifies
required files, rejects unsafe paths and duplicate members, and records the
manifest hash in release evidence. A new source, document, fixture, or package
must therefore be deliberately classified before it can enter a release
archive.

Run the checker from a clean worktree:

```sh
moon run repo-tools/tools/check_distribution.mbtx
```

The checker builds the package once with `moon package --frozen`. It obtains
the expected file set from the commit and the distribution manifest, then
compares it with the ZIP directory. It rejects missing, extra, duplicate and
unsafe file paths. It extracts a snapshot into a fresh temporary directory,
compares each file with its Git blob and runs `moon check --target all
--deny-warn --warn-list +73` on the extraction. Successful extractions are
removed. Failed extractions remain available for diagnosis.

`release_evidence.mbtx` also records the SHA-256 of the archive and each
verified member, the toolchain and resolved dependencies under
`_build/evidence/release/<revision>/`. CI keeps these local to the job.
