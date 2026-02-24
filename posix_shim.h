#ifndef POSIX_SHIM_H
#define POSIX_SHIM_H

#include <stdio.h>
#include <orbis/_types/kernel.h>

/* POSIX functions missing from PS4 SDK headers but present in libc */
int fileno(FILE *);
int fseeko(FILE *, long, int);
long ftello(FILE *);

/* kevent struct tag needs a typedef for Nim codegen */
typedef struct kevent kevent;

#endif
