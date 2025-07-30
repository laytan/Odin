#include <stdint.h>
#include <stddef.h>

void *memset(void *s, int c, size_t n);

#define KBTS_MEMSET memset

#define KB_TEXT_SHAPE_NO_CRT
#define KB_TEXT_SHAPE_IMPLEMENTATION
#include "kb_text_shape.h"
