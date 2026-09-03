// Isolated benchmark Codex stand-in: holds fixture locks or serves fixed quota RPC replies.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "hold") == 0) {
        for (int i = 2; i < argc; i++) if (open(argv[i], O_RDONLY) < 0) return 2;
        puts("READY"); fflush(stdout);
        for (;;) pause();
    }
    char *line = NULL;
    size_t length = 0;
    while (getline(&line, &length, stdin) >= 0) {
        char *field = strstr(line, "\"id\":");
        if (!field) continue;
        long id = strtol(field + 5, NULL, 10);
        const char *result = "{}";
        if (strstr(line, "account/read"))
            result = "{\"account\":{\"type\":\"chatgpt\",\"email\":\"fixture@example.invalid\"}}";
        if (strstr(line, "account/rateLimits/read")) {
            result = "{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":300}}}";
            const char *home = getenv("CODEX_HOME");
            if (home) {
                char path[4096]; snprintf(path, sizeof(path), "%s/quota-requests", home);
                FILE *log = fopen(path, "a");
                if (log) { fputs("request\n", log); fclose(log); }
            }
        }
        printf("{\"id\":%ld,\"result\":%s}\n", id, result);
        fflush(stdout);
    }
    free(line);
}
