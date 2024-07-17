//+build linux
package all

import linux    "core:sys/linux"
import io_uring "core:nbio/io_uring"

_ :: linux
_ :: io_uring
