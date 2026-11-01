#include <string.h>
#include <stdio.h>
#include "win_getopt.h"

char *optarg;
int optind = 1;
int opterr = 1;
int optopt;

static char *nextchar;

int
getopt(int argc, char *const argv[], const char *optstring)
{
	if ((nextchar == NULL) || (*nextchar == '\0'))
	{
		if ((optind >= argc) || (argv[optind][0] != '-') || (argv[optind][1] == '\0'))
			return -1;

		if (strcmp(argv[optind], "--") == 0)
		{
			optind++;
			return -1;
		}

		nextchar = argv[optind] + 1;
		optind++;
	}

	int c = *nextchar++;
	const char *spec = strchr(optstring, c);

	if ((spec == NULL) || (c == ':'))
	{
		optopt = c;
		if (opterr)
			fprintf(stderr, "unknown option -- '%c'\n", c);
		return '?';
	}

	if (spec[1] == ':')
	{
		if (*nextchar != '\0')
		{
			optarg = nextchar;
			nextchar = NULL;
		}
		else if (optind < argc)
		{
			optarg = argv[optind];
			optind++;
			nextchar = NULL;
		}
		else
		{
			optopt = c;
			if (opterr)
				fprintf(stderr, "option requires an argument -- '%c'\n", c);
			return '?';
		}
	}
	else
	{
		optarg = NULL;
	}

	return c;
}
