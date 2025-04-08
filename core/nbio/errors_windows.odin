package nbio

import     "core:reflect"
import win "core:sys/windows"

PLATFORM_ERR_UNSUPPORTED       :: win.System_Error.NOT_SUPPORTED

PLATFORM_ERR_ALLOCATION_FAILED :: win.System_Error.OUTOFMEMORY
PLATFORM_ERR_TIMEOUT           :: win.System_Error.WAIT_TIMEOUT
PLATFORM_ERR_INVALID_ARGUMENT  :: win.System_Error.BAD_ARGUMENTS
PLATFORM_ERR_OVERFLOW          :: win.System_Error.BUFFER_OVERFLOW
PLATFORM_ERR_NOT_EXIST         :: win.System_Error.FILE_NOT_FOUND

_Platform_Error :: win.System_Error

_error_string :: proc(err: Error) -> string {
	err := err
	variant := any{
		id   = reflect.union_variant_typeid(err),
		data = &err,
	}
	return reflect.enum_string(variant)
}
