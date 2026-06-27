#ifndef DEVSPACE_CPTY_H
#define DEVSPACE_CPTY_H

#include <sys/types.h>

// Thin C shims for PTY operations that aren't directly callable from Swift:
// forkpty lives in <util.h> (not exported by the Darwin overlay) and ioctl is
// variadic (variadic C functions are not imported into Swift).

// Fork a child attached to a new PTY sized rows x cols. On success returns the
// child pid (0 in the child) and writes the master fd to *amaster.
pid_t devspace_forkpty(int *amaster, unsigned short rows, unsigned short cols);

// Apply a new window size to the PTY master fd (TIOCSWINSZ). Returns 0 on success.
int devspace_set_winsize(int fd, unsigned short rows, unsigned short cols);

#endif
