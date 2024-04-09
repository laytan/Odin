package main

import "core:fmt"
import "core:os"
import "core:container/avl"
import "core:encoding/endian"
import "core:strings"

// TODO: pretty sure the instrumentation enter can be optimized out, meaning we might not have the right filepath & line association.

main :: proc() {
	tree, _ := parse_into_tree("coverage.out")

	fmt.printfln("%i lines covered", avl.len(&tree))

	file, file_path: string
	off, line: int

	iter := avl.iterator(&tree, .Forward)
	for node in avl.iterator_next(&iter) {
		loc := node.value
		if file_path != string(loc.file_path) {
			delete(file)

			fdata, fok := os.read_entire_file(loc.file_path)
			assert(fok, loc.file_path)

			file = string(fdata)
			file_path = loc.file_path
			off  = 0
			line = 0

			fmt.println(loc.file_path)
		}
		// fmt.printfln("%i ", loc.line)

		for len(file) > off {
			line_len := strings.index_byte(file[off:], '\n')
			if line_len == -1 do line_len = len(file)-off

			if line == int(loc.line)-1 {
				fmt.printfln("% 4i: \033[32m%s\033[0m", line, file[off:][:line_len])
				off  += line_len+1
				line += 1
				break
			} else {
				fmt.printfln("% 4i: \033[31m%s\033[0m", line, file[off:][:line_len])
				off  += line_len+1
				line += 1
			}
		}
	}
}

loc_cmp :: proc(a, b: Location) -> avl.Ordering {
	switch {
	case a.file_path > b.file_path: return .Greater
	case b.file_path > a.file_path: return .Less
	case a.line > b.line:           return .Greater
	case b.line > a.line:           return .Less
	// case a.column > b.column:       return .Greater
	// case b.column > a.column:       return .Less
	case:
		// assert(a.procedure == b.procedure, "duplicate location with different procedure?")
		return .Equal
	}
}

// TODO: can be much more efficient on memory, should intern it.

Location :: struct {
	file_path: string,
	line:      i32,
}

parse_into_tree :: proc(coverage_path: string, allocator := context.allocator) -> (tree: avl.Tree(Location), i: strings.Intern) {
	strings.intern_init(&i, allocator, allocator)
	reserve(&i.entries, 2048)

	avl.init(&tree, loc_cmp, allocator)

	stack := make([dynamic]string, 0, 64, context.temp_allocator)
	append(&stack, "")

	data, ok := os.read_entire_file(coverage_path, context.temp_allocator)
	assert(ok, "bad read")

	assert(data[0] == 'o' && data[1] == 'c', "signature mismatch")
	assert(data[2] == 1, "version mismatch")

	assert(data[3] == 1 || data[3] == 0, "corrupt endian")
	endianness := endian.Byte_Order.Little if data[3] == 1 else endian.Byte_Order.Big

	data = data[4:] // NOTE: could be oob

	lcp := string(cstring(raw_data(data)))
	data = data[len(lcp)+1:] // NOTE: could be oob

	fpb: [1024]byte = ---

	fp: string

	for len(data) > 0 {
		loc: Location
		loc.line = endian.get_i32(data, endianness) or_else panic("corrupt")
		data     = data[size_of(i32):]

		if loc.line == -1 {
			fpsuffix := string(cstring(raw_data(data)))

			fpn := copy(fpb[:], lcp)
			fpn += copy(fpb[fpn:], fpsuffix)
			fpn += copy(fpb[fpn:], ".odin")

			fp, _ = strings.intern_get(&i, string(fpb[:fpn]))
			data  = data[len(fpsuffix)+1:]

			append(&stack, fp)
			fmt.print(">")
			continue
		} else if loc.line == -2 {
			pop(&stack)
			fp = stack[len(stack)-1]
			fmt.print("<")
			continue
		}

		loc.file_path = fp

		n, inserted := avl.find_or_insert(&tree, loc) or_else panic("out of memory?")
		assert(n != nil, "not inserted")
		fmt.print("+" if inserted else "-")
	}

	return
}
