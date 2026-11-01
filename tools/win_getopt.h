#ifndef __WIN_GETOPT_H__
#define __WIN_GETOPT_H__ 1

/* MSVC has no getopt(). Minimal POSIX-compatible implementation covering
 * what UTILS_GETOPT_STR actually uses: "x" flags and "x:" required-args,
 * bundled short options (e.g. -lvi), '--' end-of-options, '?' on error. */

extern char *optarg;
extern int optind;
extern int opterr;
extern int optopt;

int getopt(int argc, char *const argv[], const char *optstring);

#endif /* !__WIN_GETOPT_H__ */
