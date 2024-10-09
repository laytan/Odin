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

	Allocation_Failed,
	Unsupported       = PLATFORM_ERR_UNSUPPORTED,
}

// Errors gotten from file system operations.
FS_Error :: enum i32 {
	None,
	Allocation_Failed  = PLATFORM_ERR_ALLOCATION_FAILED,
	Timeout            = PLATFORM_ERR_TIMEOUT,
	Invalid_Argument   = PLATFORM_ERR_INVALID_ARGUMENT,
	Overflow           = PLATFORM_ERR_OVERFLOW,

	// TODO:
	// Permission_Denied = PLATFORM_ERR_PERMISSION_DENIED,
	// Exist             = PLATFORM_ERR_EXISTS,
	// Not_Exist         = PLATFORM_ERR_NOT_EXISTS,
}

Platform_Error :: _Platform_Error

/*
Returns the error as the underlying platform's error type.

NOTE: usage of this means code is no longer cross-platform.
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
