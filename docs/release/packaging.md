# Distribution contents

Status: canonical
Scope: the `0.7.0` MoonBit module archive
Last reviewed: 2026-10-01
Source of truth: [`repo-tools/tools/distribution.json`](https://github.com/ZSeanYves/MoonbitHTTP/blob/main/repo-tools/tools/distribution.json)
Enforcement: [`repo-tools/tools/check_distribution.mbtx`](https://github.com/ZSeanYves/MoonbitHTTP/blob/main/repo-tools/tools/check_distribution.mbtx)

The published archive is a user library distribution. It contains the library
packages, generated public interfaces, colocated tests and benchmarks, the
`internal/test_support` package, Native TLS certificate fixtures, and the small set of
current user documentation named by the manifest. Colocated tests stay in the
archive because downstream users must be able to run the package's tests after
unpacking it; test fixtures stay with the Native TLS package for the same
reason.

The archive does not contain repository automation, command examples,
development scripts, historical reports, generated build output, or release
evidence. Those files remain useful to contributors but are not part of the
library contract. A directory called `internal` would not provide this
boundary by itself, so packaging is controlled by the explicit manifest and
the matching `.moonignore` rules.

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
local package archive. It does not publish anything. `release_evidence.mbtx`
invokes the same checker before it performs its Git blob and SHA-256 checks.
