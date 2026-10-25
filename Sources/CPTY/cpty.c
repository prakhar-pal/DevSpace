#include "cpty.h"

#if defined(__linux__)
#include <pty.h>
#else
#include <util.h>
#endif
#include <sys/ioctl.h>
#include <sys/file.h>
#include <stddef.h>

pid_t devspace_forkpty(int *amaster, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return forkpty(amaster, NULL, NULL, &ws);
}

int devspace_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int devspace_flock(int fd, int operation) {
    return flock(fd, operation);
}
