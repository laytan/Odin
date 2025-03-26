package nbio

import "base:intrinsics"

import "core:time"

@(private)
unall :: intrinsics.unaligned_load
@(private)
unals :: intrinsics.unaligned_store

timeout_poly :: proc(dur: time.Duration, p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	completion := _timeout(io(), dur, nil, proc(completion: rawptr) {
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

timeout_poly2 :: proc(dur: time.Duration, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	completion := _timeout(io(), dur, nil, proc(completion: rawptr) {
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

timeout_poly3 :: proc(dur: time.Duration, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	completion := _timeout(io(), dur, nil, proc(completion: rawptr) {
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

next_tick_poly :: proc(p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _next_tick(io(), nil, proc(completion: rawptr) {
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

next_tick_poly2 :: proc(p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _next_tick(io(), nil, proc(completion: rawptr) {
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

next_tick_poly3 :: proc(p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _next_tick(io(), nil, proc(completion: rawptr) {
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
