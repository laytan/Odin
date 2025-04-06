#+build darwin, freebsd, netbsd, openbsd
#+private
package nbio

import "core:sys/posix"

PLATFORM_ERR_UNSUPPORTED       :: posix.ENOSYS

PLATFORM_ERR_ALLOCATION_FAILED :: posix.ENOMEM
PLATFORM_ERR_TIMEOUT           :: posix.ETIMEDOUT
PLATFORM_ERR_INVALID_ARGUMENT  :: posix.EINVAL
PLATFORM_ERR_OVERFLOW          :: posix.E2BIG
PLATFORM_ERR_NOT_EXIST         :: posix.ENOENT

_Platform_Error :: posix.Errno

_error_string :: proc(err: Error) -> string {
	return string(posix._strerror(platform_error(err)))
}
