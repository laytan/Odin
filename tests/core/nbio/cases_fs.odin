package tests_nbio

import    "core:nbio"
import    "core:sync"
import    "core:testing"
import    "core:thread"
import    "core:time"
import os "core:os/os2"

@(test)
close_invalid_handle_works :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	testing.set_fail_timeout(t, time.Second)

	nbio.close_poly(max(nbio.Handle), t, proc(t: ^testing.T, err: nbio.FS_Error) {
		e(t, err != nil)
	})

	ev(t, nbio.run(), nil)
}

@(test)
write_read_close :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	testing.set_fail_timeout(t, time.Second)

	handle, errno := nbio.open(
		"test_write_read_close",
		{.Read, .Write, .Create, .Trunc},
		0o777,
	)
	ev(t, errno, nil)

	State :: struct {
		buf: [20]byte,
		fd:  nbio.Handle,
	}

	CONTENT :: [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}

	state := State{
		buf = CONTENT,
		fd = handle,
	}

	nbio.write_entire_file2(handle, state.buf[:], t, &state, proc(t: ^testing.T, state: ^State, written: int, err: nbio.FS_Error) {
		ev(t, written, len(state.buf))
		ev(t, err, nil)

		nbio.read_at_all_poly2(state.fd, 0, state.buf[:], t, state, proc(t: ^testing.T, state: ^State, read: int, err: nbio.FS_Error) {
			ev(t, read, len(state.buf))
			ev(t, err, nil)
			ev(t, state.buf, CONTENT)

			nbio.close_poly2(state.fd, t, state, proc(t: ^testing.T, state: ^State, err: nbio.FS_Error) {
				ev(t, err, nil)
				os.remove("test_write_read_close")
			})
		})
	})

	ev(t, nbio.run(), nil)
}

@(test)
usage_across_threads :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	testing.set_fail_timeout(t, time.Second)

	handle: nbio.Handle
	thread_done: sync.One_Shot_Event

	open_thread := thread.create_and_start_with_poly_data3(t, &handle, &thread_done, proc(t: ^testing.T, handle: ^nbio.Handle, thread_done: ^sync.One_Shot_Event) {
		if !check_support(t) { return }
		defer nbio.destroy()

		fd, errno := nbio.open(#file)
		ev(t, errno, nil)

		sync.atomic_store(handle, fd)
		sync.one_shot_event_signal(thread_done)
	}, init_context=context)

	sync.one_shot_event_wait(&thread_done)
	thread.destroy(open_thread)

	buf: [128]byte
	nbio.read_at_poly(handle, 0, buf[:], t, proc(t: ^testing.T, read: int, errno: nbio.FS_Error) {
		ev(t, errno, nil)
		e(t, read > 0)
	})

	nbio.run()
}

@(test)
remove_timeout :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	hit: bool
	timeout := nbio.timeout_poly(time.Second, &hit, proc(hit: ^bool) {
		hit^ = true
	})

	nbio.remove(timeout)

	ev(t, nbio.run(), nil)

	e(t, !hit)
}