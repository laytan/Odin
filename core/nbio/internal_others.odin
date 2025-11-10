#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !linux
#+build !windows
#+private
package nbio

import "base:runtime"

import "core:time"

// TODO: update with thread local stuff.

_IO :: struct #no_copy {
	// NOTE: num_waiting is also changed in JS.
	num_waiting: int,
	now:         time.Time,
	// TODO: priority queue, or that other sorted list.
	pending:     [dynamic]^Completion,
	done:        [dynamic]^Completion,
	free_list:   [dynamic]^Completion,
	allocator:   runtime.Allocator,
}
#assert(offset_of(_IO, num_waiting) == 0, "Relied upon in JS")

_Completion :: struct {
	ctx:     runtime.Context,
	cb:      proc(user: rawptr),
	timeout: time.Time,
}

_Handle :: distinct i32

new_completion :: proc(io: ^IO) -> ^Completion {
	res, err := new(Completion, io.allocator)
	if err != nil {
		panic("nbio completion instance could not be allocated")
	}
	return res
}

push_done :: proc(io: ^IO, completed: ^Completion) {
	_, err := append(&io.done, completed)
	if err != nil {
		panic("nbio done queue allocation failure")
	}
}

push_pending :: proc(io: ^IO, completed: ^Completion) {
	_, err := append(&io.pending, completed)
	if err != nil {
		panic("nbio pending queue allocation failure")
	}
}
