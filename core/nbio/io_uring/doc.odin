/*
Wrapper/convenience package over the raw io_uring syscalls, providing help with setup, creation, and operating the ring.

The following example shows a simple `cat` program implementation using the package.

Example:
    package main

    import       "base:runtime"

    import       "core:fmt"
    import       "core:os"
    import       "core:sys/linux"
    import uring "core:nbio/io_uring"

    main :: proc() {
        if len(os.args) < 2 {
            fmt.eprintfln("Usage: %s [file name] <[file name] ...>", os.args[0])
            os.exit(1)
        }

        buffers := make([][]byte, len(os.args)-1)
        defer delete(buffers)

        ring, err := uring.make(&{})
        fmt.assertf(err == nil, "uring.make: %v", err)
        defer uring.destroy(&ring)

        for _, i in os.args[1:] {
            submit_read_request(runtime.args__[i], &buffers[i], &ring)
            get_completion_and_print(&ring)
        }
    }

    submit_read_request :: proc(path: cstring, buffer: ^[]byte, ring: ^uring.IO_Uring) {
        fd, err := linux.open(path, {})
        fmt.assertf(err == nil, "open(%q): %v", path, err)

        file_sz := get_file_size(fd)

        buf := make([]byte, file_sz)
        buffer^ = buf

        _, ok := uring.read(ring, u64(uintptr(buffer)), fd, buf, 0)
        assert(ok, "could not get read sqe")

        _, err = uring.submit(ring)
        fmt.assertf(err == nil, "uring.submit: %v", err)
    }

    get_completion_and_print :: proc(ring: ^uring.IO_Uring) {
        cqes: [1]linux.IO_Uring_CQE
        n, err := uring.copy_cqes(ring, cqes[:], 1)
        fmt.assertf(err == nil, "copy_cqes: %v", err)
        assert(n == 1)
        cqe := cqes[0]

        fmt.assertf(cqe.res >= 0, "read failed: %v", linux.Errno(-cqe.res))

        buffer := (^[]byte)(uintptr(cqe.user_data))
        fmt.println(string(buffer^))
        delete(buffer^)
    }

    get_file_size :: proc(fd: linux.Fd) -> uint {
        st: linux.Stat
        err := linux.fstat(fd, &st)
        fmt.assertf(err == nil, "fstat: %v", err)

        if linux.S_ISREG(st.mode) {
            return uint(st.size)
        }

        panic("not a regular file")
    }
*/
package io_uring