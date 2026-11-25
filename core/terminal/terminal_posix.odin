#+private
#+build linux, darwin, netbsd, openbsd, freebsd
package terminal

import "base:runtime"
import "core:os"
import "core:sys/posix"

_is_terminal :: proc "contextless" (f: ^os.File) -> bool {
	return os.is_tty(f)
}

_init_terminal :: proc "contextless" () {
	context = runtime.default_context()
	color_depth = get_environment_color()
}

_fini_terminal :: proc "contextless" () { }

@(private="file")
_termination_handler: Termination_Handler
@(private="file")
_termination_handler_user_data: rawptr

_set_termination_handler :: proc(handler: Termination_Handler, user_data: rawptr) -> bool {
	when ODIN_NO_CRT {
		_ :: posix

		return false
	} else {
		if handler == nil {
			if _termination_handler != nil {
				posix.signal(.SIGINT,  auto_cast posix.SIG_DFL)
				posix.signal(.SIGTERM, auto_cast posix.SIG_DFL)
			}

			_termination_handler = nil
			_termination_handler_user_data = nil
			return true
		}

		if _termination_handler != nil {
			return false
		}

		int_ret  := posix.signal(.SIGINT,  _handler)
		if int_ret == auto_cast posix.SIG_ERR {
			return false
		}

		term_ret := posix.signal(.SIGTERM, _handler)
		if term_ret == auto_cast posix.SIG_ERR {
			posix.signal(.SIGINT, int_ret)
			return false
		}

		_termination_handler = handler
		_termination_handler_user_data = user_data

		return true

		_handler :: proc "c" (sig: posix.Signal) {
			assert_contextless(_termination_handler != nil)
			if !_termination_handler(_termination_handler_user_data) {
				posix.signal(sig, auto_cast posix.SIG_DFL)
				posix.raise(sig)
			}
		}
	}
}
