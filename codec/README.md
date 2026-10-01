# MoonbitHTTP/codec

Runtime-independent incremental byte buffering shared by protocol state
machines. It provides bounded feed, line parsing, prefix inspection, and
structured codec errors.

`huffman_encode` and `huffman_decode` implement the RFC 7541 Appendix B code
used by both HPACK and QPACK. They accept byte views and share private tables
initialized once per runtime. Encoding covers every byte; decoding returns
typed `HuffmanError` values for invalid codes, EOS in data and invalid padding.
Protocol packages map these errors at their compression boundary.
