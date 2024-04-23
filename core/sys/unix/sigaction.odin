package unix

when ODIN_OS == .Darwin {
	foreign import lib "system:System.framework"
} else  {
	foreign import lib "system:c"
}

import "core:c"
import "core:c/libc"

Sig_Handler :: #type proc "c" (Signal)

// NOTE: you can't do this using constants, and we can't put variables in
// readonly sections yet, so this will have to do.
// SIG_DFL  := cast(Sig_Handler)rawptr(uintptr(0))
// SIG_IGN  := cast(Sig_Handler)rawptr(uintptr(1))
// SIG_HOLD := cast(Sig_Handler)rawptr(uintptr(5))
// SIG_ERR  := cast(Sig_Handler)rawptr(max(uintptr))

// Returns a handler that executes the default action for the signal.
SIG_DFL :: #force_inline proc "contextless" () -> Sig_Handler {
	return nil
}
// Returns a handler that ignores the signal.
SIG_IGN :: #force_inline proc "contextless" () -> Sig_Handler {
	return Sig_Handler(rawptr(uintptr(1)))
}
// Returns a handler that holds the signal.
SIG_HOLD :: #force_inline proc "contextless" () -> Sig_Handler {
	return Sig_Handler(rawptr(uintptr(5)))
}
// Returns the return value from `signal` in case of an error.
// Example: `if unix.signal(.HUP, handler) == SIG_ERR() {`
SIG_ERR :: #force_inline proc "contextless" () -> Sig_Handler {
	return Sig_Handler(rawptr(max(uintptr)))
}

Signal :: enum c.int {
	HUP = 1, // terminal line hangup
	INT,     // interrupt program
	QUIT,    // quit program
	ILL,     // illegal instruction
	TRAP,    // trace trap
	ABRT,    // abort(3) call (formerly SIGIOTP)
	EMT,     // emulate instruction executed
	FPE,     // floating-point exception
	KILL,    // kill program
	BUS,     // bus error
	SEGV,    // segmentation fault
	SYS,     // non-existent system call invoked
	PIPE,    // write on a pipe with no reader
	ALRM,    // real-time timer expired
	TERM,    // software termination signal
	URG,     // urgent condition present on socket
	STOP,    // stop (cannot be caught or ignored)
	TSTP,    // stop signal generated from keyboard
	CONT,    // continue after stop
	CHLD,    // child status has changed
	TTIN,    // background read attempted from control terminal
	TTOU,    // background write attempted to control terminal
	IO,      // I/O is possible on a descriptor (see fcntl(2))
	XCPU,    // cpu time limit exceeded (see setrlimit(2))
	XFSZ,    // file size limit exceeded (see setitimer(2))
	VTALRM,  // virtual time alarm (see setitimer(2))
	PROF,    // profiling timer alarm (see setitimer(2))
	WINCH,   // window size change
	INFO,    // status request from keyboard
	USR1,    // user defined signal 1
	USR2,    // user defined signal 2
}

Sig_Flag :: enum c.int {
	ONSTACK = 1, // If set, the system will deliver the signal to the process on a signal stack,
	             // specified with sigaltstack(2).

	RESTART,     // If the signal is caught during a system call, the call may be forced to terminate
	             // with EINTR, the call may be restarted by setting this bit.

	RESETHAND,   // If set, the handler is reset back to default at the moment the signal is delivered.

	NOCLDSTOP,   // When this bit is set registering for a CHLD signal,
	             // the signal will only be generated when the child process exits, not when it stops.

	NODEFER,     // If set, further occurrences (during the handler) of the signal are not masked.

	NOCLDWAIT,   // If set for the CHLD signal, the system will not create zombie processes 
	             // when children of the calling process exit. If the calling process
	             // issues a wait(2) (or equivalent), it blocks until all of the children terminate,
	             // and then returns -1 with errno set to ECHILD.

	SIGINFO,     // If set, the handler is assumed to be a sigaction handler.
}

Sig_Flags :: bit_set[Sig_Flag; c.int]

Sigset :: u32

Sig_Action :: struct {
	using _u: struct #raw_union {
		handler:   Sig_Handler,
		// TODO: define the ptr things in here.
		sigaction: proc "c" (Signal, rawptr, rawptr),
	},
	flags: Sig_Flags,
	mask:  Sigset,
}

foreign lib {
	sigaction  :: proc(sig: Signal, act: ^Sig_Action, oact: ^Sig_Action) -> c.int ---
	siglongjmp :: proc(env: ^libc.jmp_buf, val: c.int) ---
	sigsetjmp  :: proc(env: ^libc.jmp_buf, savesigs: b32) -> c.int ---
}

signal :: #force_inline proc(sig: Signal, handler: Sig_Handler) -> Sig_Handler {
	return cast(Sig_Handler)libc.signal(c.int(sig), cast(proc "c" (c.int))handler)
}

raise :: #force_inline proc(sig: Signal) -> c.int {
	return libc.raise(c.int(sig))
}
