#!/bin/sh
set -ex

mkdir -p "../lib"
$CC -O2 -c kb_text_shape.c -DKB_TEXT_SHAPE_POINTER_SIZE=4 --target=wasm32
cp kb_text_shape.o ../lib/kb_text_shape_wasm.o
rm *.o
