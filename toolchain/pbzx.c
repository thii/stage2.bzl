/* pbzx: decode Apple's pbzx-wrapped pkg Payload to the raw cpio stream.
 *
 * Format: "pbzx" magic, a big-endian u64 flags word, then chunks of
 * { u64 flags, u64 compressed_size, data }. Chunk data is either an
 * xz stream (magic FD 37 7A 58 5A 00) or a raw copy.
 *
 * Usage: pbzx IN OUT
 */
#include <lzma.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t be64(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++)
        v = v << 8 | p[i];
    return v;
}

static void die(const char *msg) {
    fprintf(stderr, "pbzx: %s\n", msg);
    exit(1);
}

int main(int argc, char **argv) {
    if (argc != 3)
        die("usage: pbzx IN OUT");
    FILE *in = fopen(argv[1], "rb");
    FILE *out = fopen(argv[2], "wb");
    if (!in || !out)
        die("cannot open input/output");

    unsigned char hdr[16];
    if (fread(hdr, 1, 12, in) != 12 || memcmp(hdr, "pbzx", 4) != 0)
        die("not a pbzx stream");

    /* Decompressed chunks are bounded by the flags word's chunk size
     * (16 MiB in every observed payload); double it for safety. */
    size_t cap = 32 << 20;
    unsigned char *cbuf = malloc(cap), *dbuf = malloc(cap);
    if (!cbuf || !dbuf)
        die("out of memory");

    for (;;) {
        size_t got = fread(hdr, 1, 16, in);
        if (got == 0)
            break;
        if (got != 16)
            die("truncated chunk header");
        uint64_t size = be64(hdr + 8);
        if (size > cap)
            die("chunk larger than expected");
        if (fread(cbuf, 1, size, in) != size)
            die("truncated chunk");
        if (size >= 6 && memcmp(cbuf, "\xfd""7zXZ\0", 6) == 0) {
            uint64_t memlimit = UINT64_MAX;
            size_t in_pos = 0, out_pos = 0;
            lzma_ret r = lzma_stream_buffer_decode(
                &memlimit, 0, NULL, cbuf, &in_pos, size, dbuf, &out_pos, cap);
            if (r != LZMA_OK)
                die("xz chunk decode failed");
            if (fwrite(dbuf, 1, out_pos, out) != out_pos)
                die("write failed");
        } else {
            if (fwrite(cbuf, 1, size, out) != size)
                die("write failed");
        }
    }
    if (fclose(out) != 0)
        die("close failed");
    return 0;
}
