These public test-only keys and self-signed certificates are deliberately
committed for reproducible, offline TLS regression tests. Never use them as
application credentials. `localhost` has DNS `localhost` and IP `127.0.0.1`
subject alternatives and both serverAuth/clientAuth usage. `other` is a
separate trust identity. `expired` is valid only from 2020-01-01 to 2021-01-01.
`wildcard` has only the `*.example.test` DNS subject alternative; tests use it
to cover a valid single-label wildcard and rejection of the base domain.

Regenerate from the module root with
`moon run scripts/generate_tls_fixtures.mbtx`. The generator requires OpenSSL
3.6 or newer for explicit certificate validity options; normal tests need only
the committed PEM fixtures and the OpenSSL 3 runtime shared library.
