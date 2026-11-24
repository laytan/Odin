#+build darwin, linux, freebsd, openbsd, netbsd
package tests_nbio

import "core:log"
import "core:nbio"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private="file")
_signal_test_op: ^nbio.Operation

@(test)
exec_urgent_from_signal_handler :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	if event_loop_guard(t) {
		sock, _ := open_next_available_local_port(t)

		accept := nbio.accept(sock, proc(_: ^nbio.Operation) {
			log.error("shouldn't be called")
		})
		ev(t, nbio.tick(timeout=0), nil)

		@static ran: bool
		ran = false

		op := nbio.prep_next_tick(proc(_: ^nbio.Operation) {
			ran = true
		})
		sync.atomic_store(&_signal_test_op, op)

		prev := posix.signal(.SIGUSR1, proc "c" (_: posix.Signal) {
			if op := sync.atomic_exchange(&_signal_test_op, nil); op != nil {
				nbio.exec_urgent(op)
			}
		})
		defer posix.signal(.SIGUSR1, prev)

		target_tid := posix.pthread_self()
		thr := thread.create_and_start_with_poly_data(target_tid, proc(tid: posix.pthread_t) {
			time.sleep(20 * time.Millisecond)
			posix.pthread_kill(tid, .SIGUSR1)
		}, context)
		defer thread.destroy(thr)

		for !ran {
			ev(t, nbio.tick(), nil)
		}
		e(t, ran)

		nbio.remove(accept)
		nbio.close(sock)
		ev(t, nbio.run(), nil)
	}
}
