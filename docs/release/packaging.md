# Distribution contents

Status: canonical
Scope: the `0.7.0` MoonBit module archive
Last reviewed: 2026-10-06
Source of truth: [`repo-tools/tools/distribution.json`](https://github.com/ZSeanYves/MoonbitHTTP/blob/main/repo-tools/tools/distribution.json)
Enforcement: [`repo-tools/tools/check_distribution.mbtx`](https://github.com/ZSeanYves/MoonbitHTTP/blob/main/repo-tools/tools/check_distribution.mbtx)

The published archive is a user library distribution. It contains the library
packages, generated public interfaces, colocated tests and benchmarks, the
`internal/test_support` package, and the current user documentation named by the
manifest. Native TLS certificate, private-key and revocation fixtures are
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

The checker invokes `moon package --frozen --list`; it may regenerate the
local package archive. It does not publish anything. It rejects `_build`,
`target`, `.mooncakes`, coverage, evidence and zip members, then compares each
archive member with the frozen Git blob. `release_evidence.mbtx` invokes the
same checker before it performs its Git blob and SHA-256 checks. Neither tool
uploads artifacts; CI keeps their temporary outputs only for the job lifetime.
