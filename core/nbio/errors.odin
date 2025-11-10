package nbio

import "base:intrinsics"

import "core:net"

Error :: intrinsics.type_merge(
	net.Network_Error,
	union #shared_nil {
		General_Error,
		FS_Error,
	},
)
#assert(size_of(Error) == 8)

// Errors regarding general usage of the event loop.
General_Error :: enum i32 {
	None,

	Allocation_Failed = i32(PLATFORM_ERR_ALLOCATION_FAILED),
	Unsupported       = i32(PLATFORM_ERR_UNSUPPORTED),
}

// Errors gotten from file system operations.
FS_Error :: enum i32 {
	None,
	Unsupported        = i32(PLATFORM_ERR_UNSUPPORTED),
	Allocation_Failed  = i32(PLATFORM_ERR_ALLOCATION_FAILED),
	Timeout            = i32(PLATFORM_ERR_TIMEOUT),
	Invalid_Argument   = i32(PLATFORM_ERR_INVALID_ARGUMENT),
	Overflow           = i32(PLATFORM_ERR_OVERFLOW),

	// TODO:
	// Permission_Denied = PLATFORM_ERR_PERMISSION_DENIED,
	// Exist             = PLATFORM_ERR_EXISTS,
	Not_Exist         = i32(PLATFORM_ERR_NOT_EXIST),
}

Platform_Error :: _Platform_Error

/*
Returns the error as the underlying platform's error type.

NOTE: return value is not cross platform.
*/
platform_error :: proc(err: Error) -> Platform_Error {
	err := err
	return (^Platform_Error)(&err)^
}

/*
Returns a string representation of the error.

NOTE: returned string memory may be reused for subsequent calls and should be copied if held onto.
*/
error_string :: proc(err: Error) -> string {
	return _error_string(err)
}
