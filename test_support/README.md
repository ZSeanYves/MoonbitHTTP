# MoonbitHTTP/test_support

Reusable fragmentation, injected-failure Reader, recording Writer, fixed clock,
zero entropy, and in-memory datagram fixtures for protocol and connection tests.
These deterministic capabilities belong in test imports; production hosts inject
clock, entropy and transport implementations through `transport` contracts.
