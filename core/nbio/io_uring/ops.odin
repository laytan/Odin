package io_uring

import "core:sys/linux"

// Queues (but does not submit) an SQE to perform an `fsync(2)`.
// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
fsync :: proc(ring: ^IO_Uring, user_data: u64, fd: linux.Fd, flags: linux.IO_Uring_Fsync_Flags) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .FSYNC
	sqe.fsync_flags = flags
	sqe.fd = fd
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a no-op.
// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
// A no-op is more useful than may appear at first glance.
// For example, you could call `drain_previous_sqes()` on the returned SQE, to use the no-op to
// know when the ring is idle before acting on a kill signal.
nop :: proc(ring: ^IO_Uring, user_data: u64) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .NOP
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `read(2)`.
read :: proc(ring: ^IO_Uring, user_data: u64, fd: linux.Fd, buf: []u8, offset: u64) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
    assert(len(buf) < int(max(u32)))

	sqe = get_sqe(ring) or_return
	sqe.opcode = .READ
	sqe.fd = fd
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.off = offset
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `write(2)`.
write :: proc(ring: ^IO_Uring, user_data: u64, fd: linux.Fd, buf: []u8, offset: u64) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
    assert(len(buf) < int(max(u32)))

	sqe = get_sqe(ring) or_return
	sqe.opcode = .WRITE
	sqe.fd = fd
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.off = offset
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket.
accept :: proc(ring: ^IO_Uring, user_data: u64, sockfd: linux.Fd, addr: ^$T, flags: linux.Socket_FD_Flags) -> (sqe: ^linux.IO_Uring_SQE, ok: bool)
    where T == linux.Sock_Addr_In || T == linux.Sock_Addr_In6 || T == linux.Sock_Addr_Un || T == linux.Sock_Addr_Any {

    addr_len := i32(size_of(T))

	sqe = get_sqe(ring) or_return
	sqe.opcode = .ACCEPT
	sqe.fd = sockfd
	sqe.addr = cast(u64)uintptr(addr)
	sqe.off = cast(u64)uintptr(&addr_len)
	sqe.accept_flags = flags
	sqe.user_data = user_data
	return
}

// Queue (but does not submit) an SQE to perform a `connect(2)` on a socket.
connect :: proc(ring: ^IO_Uring, user_data: u64, sockfd: linux.Fd, addr: ^$T) -> (sqe: ^linux.IO_Uring_SQE, ok: bool)
    where T == linux.Sock_Addr_In || T == linux.Sock_Addr_In6 || T == linux.Sock_Addr_Un || T == linux.Sock_Addr_Any {

	sqe = get_sqe(ring) or_return
	sqe.opcode = .CONNECT
	sqe.fd = sockfd
	sqe.addr = cast(u64)uintptr(addr)
	sqe.off = size_of(T)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `recv(2)`.
recv :: proc(ring: ^IO_Uring, user_data: u64, sockfd: linux.Fd, buf: []byte, flags: linux.Socket_Msg) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
    assert(len(buf) < int(max(u32)))

	sqe = get_sqe(ring) or_return
	sqe.opcode = .RECV
	sqe.fd = sockfd
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = cast(u32)uintptr(len(buf))
	sqe.msg_flags = flags
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `send(2)`.
send :: proc(ring: ^IO_Uring, user_data: u64, sockfd: linux.Fd, buf: []byte, flags: linux.Socket_Msg) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
    assert(len(buf) < int(max(u32)))

	sqe = get_sqe(ring) or_return
	sqe.opcode = .SEND
	sqe.fd = sockfd
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.msg_flags = flags
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform an `openat(2)`.
openat :: proc(ring: ^IO_Uring, user_data: u64, fd: linux.Fd, path: cstring, mode: u32, flags: linux.Open_Flags) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .OPENAT
	sqe.fd = fd
	sqe.addr = cast(u64)transmute(uintptr)path
	sqe.len = mode
	sqe.open_flags = flags
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `close(2)`.
close :: proc(ring: ^IO_Uring, user_data: u64, fd: linux.Fd) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .CLOSE
	sqe.fd = fd
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to register a timeout operation.
// Returns a pointer to the SQE.
//
// The timeout will complete when either the timeout expires, or after the specified number of
// events complete (if `count` is greater than `0`).
//
// `flags` may be `0` for a relative timeout, or `IORING_TIMEOUT_ABS` for an absolute timeout.
//
// The completion event result will be `-ETIME` if the timeout completed through expiration,
// `0` if the timeout completed after the specified number of events, or `-ECANCELED` if the
// timeout was removed before it expired.
//
// io_uring timeouts use the `CLOCK.MONOTONIC` clock source.
timeout :: proc(ring: ^IO_Uring, user_data: u64, ts: ^linux.Time_Spec, count: u32, flags: linux.IO_Uring_Timeout_Flags) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .TIMEOUT
	sqe.fd = -1
	sqe.addr = cast(u64)uintptr(ts)
	sqe.len = 1
	sqe.off = u64(count)
	sqe.timeout_flags = flags
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to remove an existing timeout operation.
// Returns a pointer to the SQE.
//
// The timeout is identified by it's `user_data`.
//
// The completion event result will be `0` if the timeout was found and cancelled successfully,
// `-EBUSY` if the timeout was found but expiration was already in progress, or
// `-ENOENT` if the timeout was not found.
timeout_remove :: proc(ring: ^IO_Uring, user_data: u64, timeout_user_data: u64, flags: linux.IO_Uring_Timeout_Flags) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .TIMEOUT_REMOVE
	sqe.fd = -1
	sqe.addr = timeout_user_data
	sqe.timeout_flags = flags
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to add a link timeout operation.
// Returns a pointer to the SQE.
//
// You need to set linux.IOSQE_IO_LINK to flags of the target operation
// and then call this method right after the target operation.
// See https://lwn.net/Articles/803932/ for detail.
//
// If the dependent request finishes before the linked timeout, the timeout
// is canceled. If the timeout finishes before the dependent request, the
// dependent request will be canceled.
//
// The completion event result of the link_timeout will be
// `-ETIME` if the timeout finishes before the dependent request
// (in this case, the completion event result of the dependent request will
// be `-ECANCELED`), or
// `-EALREADY` if the dependent request finishes before the linked timeout.
link_timeout :: proc(ring: ^IO_Uring, user_data: u64, ts: ^linux.Time_Spec, flags: linux.IO_Uring_Timeout_Flags) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .LINK_TIMEOUT
	sqe.fd = -1
	sqe.addr = cast(u64)uintptr(ts)
	sqe.len = 1
	sqe.timeout_flags = flags
	sqe.user_data = user_data
	return
}

poll_add :: proc(ring: ^IO_Uring, user_data: u64, fd: linux.Fd, events: linux.Fd_Poll_Events, flags: linux.IO_Uring_Poll_Add_Flags) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .POLL_ADD
	sqe.fd = fd
	sqe.poll_events = events
	sqe.poll_flags = flags
	sqe.user_data = user_data
	return
}

poll_remove :: proc(ring: ^IO_Uring, user_data: u64, fd: linux.Fd, events: linux.Fd_Poll_Events) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .POLL_REMOVE
	sqe.fd = fd
	sqe.poll_events = events
	sqe.user_data = user_data
	return
}

// TODO: other ops.