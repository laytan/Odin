package nbio

import "base:intrinsics"

import "core:time"

/*
Each time you call this the IO implementation checks its state
and calls any callbacks which are ready. You would typically call this in a loop.

Blocks for up-to 10ms waiting for events if there is nothing to do.

Inputs:
- io: The IO instance to tick

Returns:
- err: An error code when something went when retrieving events, 0 otherwise
*/
tick :: proc() -> General_Error {
	if !g_io.initialized { return nil }
	return _tick(&g_io)
}

run :: proc() -> General_Error {
	if !g_io.initialized { return nil }
	for _num_waiting(&g_io) > 0 {
		if errno := _tick(&g_io); errno != nil {
			return errno
		}
	}
	return nil
}

run_until :: proc(done: ^bool) -> General_Error {
	if !g_io.initialized { return nil }
	for _num_waiting(&g_io) > 0 && !intrinsics.volatile_load(done) {
		if errno := _tick(&g_io); errno != nil {
			return errno
		}
	}
	return nil
}

/*
Returns the number of in-progress IO to be completed.
*/
num_waiting :: proc() -> int {
	if !g_io.initialized { return 0 }
	return _num_waiting(&g_io)
}

/*
Returns the current time (of the last tick).
*/
now :: proc() -> time.Time {
	if !g_io.initialized { return time.now() }
	return _now(&g_io)
}

On_Timeout :: #type proc(user: rawptr)

/*
Schedules a callback to be called after the given duration elapses.

The accuracy depends on the time between calls to `tick`.
When you call it in a loop with no blocks or very expensive calculations in other scheduled event callbacks
it is reliable to about a ms of difference (so timeout of 10ms would almost always be ran between 10ms and 11ms).

NOTE: polymorphic variants for type safe user data are available under `timeout_poly`, `timeout_poly2`, and `timeout_poly3`.

Inputs:
- io:       The IO instance to use
- dur:      The minimum duration to wait before calling the given callback
*/
timeout :: proc(dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	return _timeout(io(), dur, user, callback)
}

On_Next_Tick :: #type proc(user: rawptr)

/*
Schedules a callback to be called during the next tick of the event loop.

NOTE: polymorphic variants for type safe user data are available under `next_tick_poly`, `next_tick_poly2`, and `next_tick_poly3`.

Inputs:
- io:   The IO instance to use
*/
next_tick :: proc(user: rawptr, callback: On_Next_Tick) -> ^Completion {
	return _next_tick(io(), user, callback)
}

/*
Removes the given target from the event loop.

Common use would be to cancel a timeout, remove a polling, or remove an `accept` before calling `close` on it's socket.
*/
remove :: proc(target: ^Completion) {
	if target == nil {
		return
	}

	_remove(io(), target)
}

// TODO: document.
// TODO: enforce target being the last added completion. You can only timeout the previously added completion.
// Maybe even not take a target at all.
with_timeout :: proc(dur: time.Duration, target: ^Completion, loc := #caller_location) -> ^Completion {
	if target == nil || dur == 0 { return nil }
	return _timeout_completion(io(), dur, target)
}

Handle :: _Handle

// TODO: should this be configurable, with a minimum of course for the use of core?
MAX_USER_ARGUMENTS :: 5

Completion :: struct {
	// Implementation specifics, don't use outside of implementation/os.
	using _:   _Completion,

	user_data: rawptr,

	// Callback pointer and user args passed in poly variants.
	user_args: [MAX_USER_ARGUMENTS + 1]rawptr,
}
