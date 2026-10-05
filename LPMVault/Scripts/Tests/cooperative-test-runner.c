#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fputs("Expected a Swift Testing helper and test bundle.\n", stderr);
        return 2;
    }

    char **arguments = calloc((size_t)argc + 2, sizeof(*arguments));
    if (arguments == NULL) {
        perror("Allocate test runner arguments");
        return 1;
    }
    arguments[0] = argv[1];
    arguments[1] = "--test-bundle-path";
    arguments[2] = argv[2];
    for (int index = 3; index < argc; ++index) {
        arguments[index] = argv[index];
    }
    arguments[argc] = argv[2];

    // A compiled launcher preserves SwiftPM's DYLD paths, which macOS strips from shell launchers.
    if (setenv("LIBDISPATCH_COOPERATIVE_POOL_STRICT", "1", 1) != 0) {
        perror("Constrain the test executor");
        free(arguments);
        return 1;
    }
    execv(argv[1], arguments);
    perror("Launch Swift Testing");
    free(arguments);
    return 1;
}
