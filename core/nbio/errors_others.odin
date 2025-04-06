#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !linux
#+build !windows
package nbio

import "core:reflect"

PLATFORM_ERR_UNSUPPORTED       :: 1

PLATFORM_ERR_ALLOCATION_FAILED :: 2
PLATFORM_ERR_TIMEOUT           :: 3
PLATFORM_ERR_INVALID_ARGUMENT  :: 4
PLATFORM_ERR_OVERFLOW          :: 5
PLATFORM_ERR_NOT_EXIST         :: 6

_Platform_Error :: enum i32 {}

_error_string :: proc(err: Error) -> string {
	err := err
	variant := any{
		id   = reflect.union_variant_typeid(err),
		data = &err,
	}
	return reflect.enum_string(variant)
}
