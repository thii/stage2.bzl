/* Internal sdkprune helper: delete every Mach-O file under a tree.
 *
 * The Apple SDK is essentially text (headers plus .tbd linker stubs),
 * but each release carries a couple dozen prebuilt Mach-O leftovers:
 * pre-10.8 CRT startup objects (crt1.o, dylib1.o, ...), Tcl/Tk stub
 * archives, and stray framework bundle executables. None of them
 * participates in a modern (macos11+) link, and deleting them keeps the
 * "no prebuilt binary among action inputs" invariant literal. Deletion
 * is by file magic, not by name, so new SDK releases cannot smuggle a
 * binary past the prune.
 *
 * Usage: sdkprune DIR   (prints one line per deleted file, then a count)
 */
#define _XOPEN_SOURCE 700
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int deleted;

static int visit(const char *path, const struct stat *sb, int type, struct FTW *ftw) {
    (void)sb;
    (void)ftw;
    if (type != FTW_F)
        return 0;
    FILE *f = fopen(path, "rb");
    if (!f)
        return 0;
    unsigned char m[4];
    size_t got = fread(m, 1, 4, f);
    fclose(f);
    if (got != 4)
        return 0;
    static const unsigned char magics[6][4] = {
        {0xcf, 0xfa, 0xed, 0xfe}, {0xce, 0xfa, 0xed, 0xfe},  /* Mach-O LE */
        {0xfe, 0xed, 0xfa, 0xcf}, {0xfe, 0xed, 0xfa, 0xce},  /* Mach-O BE */
        {0xca, 0xfe, 0xba, 0xbe}, {0xbe, 0xba, 0xfe, 0xca},  /* fat */
    };
    int is_macho = 0;
    for (int i = 0; i < 6; i++)
        if (memcmp(m, magics[i], 4) == 0)
            is_macho = 1;
    /* Static archives holding Mach-O members: "!<arch>\n" is shared with
     * every ar flavor, and BSD ar's "#1/N" extended names put a variable-
     * length name before each member's data, so member offsets are not
     * fixed. Scan the first 64 KiB for a Mach-O magic at any offset —
     * those byte sequences cannot occur in text, and an SDK has no other
     * kind of archive worth keeping. */
    if (!is_macho && memcmp(m, "!<ar", 4) == 0) {
        f = fopen(path, "rb");
        if (f) {
            static unsigned char buf[64 << 10];
            size_t n = fread(buf, 1, sizeof(buf), f);
            fclose(f);
            for (size_t off = 0; off + 4 <= n && !is_macho; off++)
                for (int i = 0; i < 6; i++)
                    if (memcmp(buf + off, magics[i], 4) == 0)
                        is_macho = 1;
        }
    }
    if (is_macho) {
        if (remove(path) == 0) {
            printf("pruned: %s\n", path);
            deleted++;
        } else {
            fprintf(stderr, "sdkprune: cannot remove %s\n", path);
            exit(1);
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: sdkprune DIR\n");
        return 1;
    }
    if (nftw(argv[1], visit, 64, FTW_PHYS) != 0) {
        fprintf(stderr, "sdkprune: traversal failed\n");
        return 1;
    }
    printf("sdkprune: %d Mach-O files deleted\n", deleted);
    return 0;
}
