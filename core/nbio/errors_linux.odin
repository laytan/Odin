#+private
package nbio

import "core:reflect"
import "core:sys/linux"

PLATFORM_ERR_UNSUPPORTED       :: linux.Errno.ENOSYS

PLATFORM_ERR_ALLOCATION_FAILED :: linux.Errno.ENOMEM
PLATFORM_ERR_TIMEOUT           :: linux.Errno.ECANCELED
PLATFORM_ERR_INVALID_ARGUMENT  :: linux.Errno.EINVAL
PLATFORM_ERR_OVERFLOW          :: linux.Errno.E2BIG
PLATFORM_ERR_NOT_EXIST         :: linux.Errno.ENOENT

_Platform_Error :: linux.Errno

_error_string :: proc(err: Error) -> string {
	n, _ := reflect.enum_name_from_value(platform_error(err))
	return n
}
