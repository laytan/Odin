package nbio

import "base:intrinsics"

import "core:time"

@(private)
unall :: intrinsics.unaligned_load
@(private)
unals :: intrinsics.unaligned_store

timeout1 :: proc(io: ^IO, dur: time.Duration, p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {

	completion := _timeout(io, dur, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)), callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

timeout2 :: proc(io: ^IO, dur: time.Duration, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {

	completion := _timeout(io, dur, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)), callback)
	unals((^T) (rawptr(ptr + size_of(C))), p)
	unals((^T2)(rawptr(ptr + size_of(C) + size_of(T))), p2)

	completion.user_data = completion
	return completion
}

timeout3 :: proc(io: ^IO, dur: time.Duration, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {

	completion := _timeout(io, dur, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)), callback)
	unals((^T) (rawptr(ptr + size_of(C))), p)
	unals((^T2)(rawptr(ptr + size_of(C) + size_of(T))), p2)
	unals((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))), p3)

	completion.user_data = completion
	return completion
}

next_tick1 :: proc(io: ^IO, p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _next_tick(io, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)), callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

next_tick2 :: proc(io: ^IO, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _next_tick(io, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)), callback)
	unals((^T) (rawptr(ptr + size_of(C))), p)
	unals((^T2)(rawptr(ptr + size_of(C) + size_of(T))), p2)

	completion.user_data = completion
	return completion
}

next_tick3 :: proc(io: ^IO, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _next_tick(io, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)), callback)
	unals((^T) (rawptr(ptr + size_of(C))), p)
	unals((^T2)(rawptr(ptr + size_of(C) + size_of(T))), p2)
	unals((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))), p3)

	completion.user_data = completion
	return completion
}
