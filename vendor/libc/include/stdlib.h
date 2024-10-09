#include <stddef.h>

#pragma once

void *malloc(size_t size);

void *aligned_alloc(size_t alignment, size_t size);

void free(void *);

void *realloc(void *, size_t);

void qsort(void* base, size_t num, size_t size, int (*compare)(const void*, const void*));

int atoi(const char *);
long atol(const char *);
long long atoll(const char *);

double atof(const char *);

long strtol(const char *, char **, int);
double strtod(const char *, char **);

void abort();
void exit(int exit_code);

typedef struct {
	long int quot;
	long int rem;
} ldiv_t;

ldiv_t ldiv(long int number, long int denom);
