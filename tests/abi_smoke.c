/*
 * Smoke test for the libzdtd C ABI. Linking this program proves the static
 * archive is produced and exports the whole surface; running it proves the
 * version, lifecycle and tick contracts.
 */

#include <stdint.h>
#include <stdio.h>

#include "zdtd.h"

static int report_failure(const char *call) {
    char message[256];
    size_t n = zdtd_last_error(message, sizeof message);
    if (n == 0) {
        fprintf(stderr, "abi-smoke: %s failed without error text\n", call);
    } else {
        fprintf(stderr, "abi-smoke: %s failed: %s\n", call, message);
    }
    return 1;
}

int main(void) {
    uint32_t version = zdtd_abi_version();
    if (version != ZDTD_ABI_VERSION) {
        fprintf(stderr, "abi-smoke: ABI mismatch: library %u, header %u\n",
                (unsigned)version, (unsigned)ZDTD_ABI_VERSION);
        return 1;
    }

    zdtd_world *world = zdtd_create();
    if (world == NULL) {
        return report_failure("zdtd_create");
    }

    for (int i = 0; i < 3; i++) {
        int32_t status = zdtd_tick(world, 0.05f);
        if (status != ZDTD_OK) {
            zdtd_destroy(world);
            return report_failure("zdtd_tick");
        }
    }

    char message[256];
    if (zdtd_last_error(message, sizeof message) != 0) {
        fprintf(stderr, "abi-smoke: successful calls left error text: %s\n", message);
        zdtd_destroy(world);
        return 1;
    }

    zdtd_destroy(world);
    printf("abi-smoke: ok abi=%u ticks=3\n", (unsigned)version);
    return 0;
}
