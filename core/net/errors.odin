package net

Create_Socket_Error :: enum i32 {
	None,

	// All:
	Family_Not_Supported_For_This_Socket = i32(_CREATE_SOCKET_ERROR_FAMILY_NOT_SUPPORTED_FOR_THIS_SOCKET),
	No_Buffer_Space_Available            = i32(_CREATE_SOCKET_ERROR_NO_BUFFER_SPACE_AVAILABLE),
	// FreeBSD:
	Access_Denied                        = i32(_CREATE_SOCKET_ERROR_ACCESS_DENIED),
	Full_Per_Process_Descriptor_Table    = i32(_CREATE_SOCKET_ERROR_FULL_PER_PROCESS_DESCRIPTOR_TABLE),
	Full_System_File_Table               = i32(_CREATE_SOCKET_ERROR_FULL_SYSTEM_FILE_TABLE),
	Insufficient_Permission              = i32(_CREATE_SOCKET_ERROR_INSUFFICIENT_PERMISSION),
	Protocol_Unsupported_In_Family       = i32(_CREATE_SOCKET_ERROR_PROTOCOL_UNSUPPORTED_IN_FAMILY),
	Socket_Type_Unsupported_By_Protocol  = i32(_CREATE_SOCKET_ERROR_SOCKET_TYPE_UNSUPPORTED_BY_PROTOCOL),
	// Darwin & Linux:
	No_Memory_Available                  = i32(_CREATE_SOCKET_ERROR_NO_MEMORY_AVAILABLE),
	// Darwin & Linux & Windows:
	No_Socket_Descriptors_Available      = i32(_CREATE_SOCKET_ERROR_NO_SOCKET_DESCRIPTORS_AVAILABLE),
	Protocol_Unsupported_By_System       = i32(_CREATE_SOCKET_ERROR_PROTOCOL_UNSUPPORTED_BY_SYSTEM),
	Wrong_Protocol_For_Socket            = i32(_CREATE_SOCKET_ERROR_WRONG_PROTOCOL_FOR_SOCKET),
	Family_And_Socket_Type_Mismatch      = i32(_CREATE_SOCKET_ERROR_FAMILY_AND_SOCKET_TYPE_MISMATCH),
	// Windows:
	Network_Subsystem_Failure            = i32(_CREATE_SOCKET_ERROR_NETWORK_SUBSYSTEM_FAILURE),
}

Dial_Error :: enum i32 {
	None,

	// All:
	Port_Required               = i32(_DIAL_ERROR_PORT_REQUIRED),
	Not_Socket                  = i32(_DIAL_ERROR_NOT_SOCKET),
	Wrong_Family_For_Socket     = i32(_DIAL_ERROR_WRONG_FAMILY_FOR_SOCKET),
	Already_Connected           = i32(_DIAL_ERROR_ALREADY_CONNECTED),
	Timeout                     = i32(_DIAL_ERROR_TIMEOUT),
	Refused                     = i32(_DIAL_ERROR_REFUSED),
	Network_Unreachable         = i32(_DIAL_ERROR_NETWORK_UNREACHABLE),
	Host_Unreachable            = i32(_DIAL_ERROR_HOST_UNREACHABLE),
	Address_In_Use              = i32(_DIAL_ERROR_ADDRESS_IN_USE),
	In_Progress                 = i32(_DIAL_ERROR_IN_PROGRESS),
	// FreeBSD:
	Not_Descriptor              = i32(_DIAL_ERROR_NOT_DESCRIPTOR),
	Invalid_Namelen             = i32(_DIAL_ERROR_INVALID_NAMELEN),
	Address_Unavailable         = i32(_DIAL_ERROR_ADDRESS_UNAVAILABLE),
	Refused_By_Remote_Host      = i32(_DIAL_ERROR_REFUSED_BY_REMOTE_HOST),
	Reset_By_Remote_Host        = i32(_DIAL_ERROR_RESET_BY_REMOTE_HOST),
	Invalid_Address_Space       = i32(_DIAL_ERROR_INVALID_ADDRESS_SPACE),
	Interrupted_By_Signal       = i32(_DIAL_ERROR_INTERRUPTED_BY_SIGNAL),
	Previous_Attempt_Incomplete = i32(_DIAL_ERROR_PREVIOUS_ATTEMPT_INCOMPLETE),
	Broadcast_Unavailable       = i32(_DIAL_ERROR_BROADCAST_UNAVAILABLE),
	Auto_Port_Unavailable       = i32(_DIAL_ERROR_AUTO_PORT_UNAVAILABLE),
	// Darwin & Linux & Windows:
	Cannot_Use_Any_Address      = i32(_DIAL_ERROR_CANNOT_USE_ANY_ADDRESS),
	Is_Listening_Socket         = i32(_DIAL_ERROR_IS_LISTENING_SOCKET),
	No_Buffer_Space_Available   = i32(_DIAL_ERROR_NO_BUFFER_SPACE_AVAILABLE),
	Would_Block                 = i32(_DIAL_ERROR_WOULD_BLOCK),
}

Bind_Error :: enum i32 {
	None,

	// All:
	Already_Bound                = i32(_BIND_ERROR_ALREADY_BOUND),
	Given_Nonlocal_Address       = i32(_BIND_ERROR_GIVEN_NONLOCAL_ADDRESS),
	Address_In_Use               = i32(_BIND_ERROR_ADDRESS_IN_USE),
	Address_Family_Mismatch      = i32(_BIND_ERROR_ADDRESS_FAMILY_MISMATCH),
	// FreeBSD:
	Kernel_Resources_Unavailable = i32(_BIND_ERROR_KERNEL_RESOURCES_UNAVAILABLE),
	Not_Descriptor               = i32(_BIND_ERROR_NOT_DESCRIPTOR),
	Not_Socket                   = i32(_BIND_ERROR_NOT_SOCKET),
	Protected_Address            = i32(_BIND_ERROR_PROTECTED_ADDRESS),
	Invalid_Address_Space        = i32(_BIND_ERROR_INVALID_ADDRESS_SPACE),
	// Darwin:
	Privileged_Port_Without_Root = i32(_BIND_ERROR_PRIVILEGED_PORT_WITHOUT_ROOT),
	// Darwin & Linux & Windows:
	Broadcast_Disabled           = i32(_BIND_ERROR_BROADCAST_DISABLED),
	No_Ports_Available           = i32(_BIND_ERROR_NO_PORTS_AVAILABLE),
}

Listen_Error :: enum i32 {
	None,

	// All:
	Not_Socket                                        = i32(_LISTEN_ERROR_NOT_SOCKET),
	Would_Block                                       = i32(_LISTEN_ERROR_WOULD_BLOCK),
	// FreeBSD:
	Not_Descriptor                                    = i32(_LISTEN_ERROR_NOT_DESCRIPTOR),
	Interrupted                                       = i32(_LISTEN_ERROR_INTERRUPTED),
	Full_Per_Process_Descriptor_Table                 = i32(_LISTEN_ERROR_FULL_PER_PROCESS_DESCRIPTOR_TABLE),
	Full_System_Table                                 = i32(_LISTEN_ERROR_FULL_SYSTEM_TABLE),
	Listen_Not_Called_On_Socket_Yet                   = i32(_LISTEN_ERROR_LISTEN_NOT_CALLED_ON_SOCKET_YET), // TODO(laytan): ??? as a listen error?
	Address_Not_Writable                              = i32(_LISTEN_ERROR_ADDRESS_NOT_WRITABLE),
	No_Connections_Available                          = i32(_LISTEN_ERROR_NO_CONNECTIONS_AVAILABLE),
	New_Connection_Aborted                            = i32(_LISTEN_ERROR_NEW_CONNECTION_ABORTED),
	// Darwin & Linux & Windows:
	Address_In_Use                                    = i32(_LISTEN_ERROR_ADDRESS_IN_USE),
	Already_Connected                                 = i32(_LISTEN_ERROR_ALREADY_CONNECTED),
	No_Buffer_Space_Available                         = i32(_LISTEN_ERROR_NO_BUFFER_SPACE_AVAILABLE),
	// Linux & Windows:
	No_Socket_Descriptors_Available                   = i32(_LISTEN_ERROR_NO_SOCKET_DESCRIPTORS_AVAILABLE),
	Nonlocal_Address                                  = i32(_LISTEN_ERROR_NONLOCAL_ADDRESS),
	Listening_Not_Supported_For_This_Socket           = i32(_LISTEN_ERROR_LISTEN_NOT_SUPPORTED_FOR_THIS_SOCKET),
	// Darwin:
	No_Socket_Descriptors_Available_For_Client_Socket = i32(_LISTEN_ERROR_NO_SOCKET_DESCRIPTORS_AVAILABLE_FOR_CLIENT_SOCKET),
	Not_Connection_Oriented_Socket                    = i32(_LISTEN_ERROR_NOT_CONNECTION_ORIENTED_SOCKET),
}

Accept_Error :: enum i32 {
	None,

	// FreeBSD:
	Not_Descriptor                                    = i32(_ACCEPT_ERROR_NOT_DESCRIPTOR),
	Interrupted                                       = i32(_ACCEPT_ERROR_INTERRUPTED),
	Full_Per_Process_Descriptor_Table                 = i32(_ACCEPT_ERROR_FULL_PER_PROCESS_DESCRIPTOR_TABLE),
	Full_System_Table                                 = i32(_ACCEPT_ERROR_FULL_SYSTEM_TABLE),
	Not_Socket                                        = i32(_ACCEPT_ERROR_NOT_SOCKET),
	Listen_Not_Called_On_Socket_Yet                   = i32(_ACCEPT_ERROR_LISTEN_NOT_CALLED_ON_SOCKET_YET),
	Address_Not_Writable                              = i32(_ACCEPT_ERROR_ADDRESS_NOT_WRITABLE),
	No_Connections_Available                          = i32(_ACCEPT_ERROR_NO_CONNECTIONS_AVAILABLE),
	New_Connection_Aborted                            = i32(_ACCEPT_ERROR_NEW_CONNECTION_ABORTED),

	// Darwin:
	Reset                                             = i32(_ACCEPT_ERROR_RESET), // TODO(tetra): Is this error actually possible here? Or is like Linux, in which case we can remove it.
	// Darwin & Linux & Windows:
	Not_Listening                                     = i32(_ACCEPT_ERROR_NOT_LISTENING),
	No_Socket_Descriptors_Available_For_Client_Socket = i32(_ACCEPT_ERROR_NO_SOCKET_DESCRIPTORS_AVAILABLE_FOR_CLIENT_SOCKET),
	No_Buffer_Space_Available                         = i32(_ACCEPT_ERROR_NO_BUFFER_SPACE_AVAILABLE),
	Not_Socket                                        = i32(_ACCEPT_ERROR_NOT_SOCKET),
	Not_Connection_Oriented_Socket                    = i32(_ACCEPT_ERROR_NOT_CONNECTION_ORIENTED_SOCKET),
	Would_Block                                       = i32(_ACCEPT_ERROR_WOULD_BLOCK),
}

TCP_Recv_Error :: enum i32 {
	None,

	// All:
	Connection_Closed                    = i32(_TCP_RECV_ERROR_CONNECTION_CLOSED), // TODO(tetra): Determine when this is different from the syscall returning n=0 and maybe normalize them?
	Not_Connected                        = i32(_TCP_RECV_ERROR_NOT_CONNECTED),
	Not_Socket                           = i32(_TCP_RECV_ERROR_NOT_SOCKET),
	Timeout                              = i32(_TCP_RECV_ERROR_TIMEOUT),
	// FreeBSD:
	Not_Descriptor                       = i32(_TCP_RECV_ERROR_NOT_DESCRIPTOR),
	// NOTE(Feoramund): The next two errors are only relevant for recvmsg(),
	// but I'm including them for completeness's sake.
	Full_Table_And_Pending_Data          = i32(_TCP_RECV_ERROR_FULL_TABLE_AND_PENDING_DATA), // TODO: remove, wtf do we want with recvmsg errors
	Invalid_Message_Size                 = i32(_TCP_RECV_ERROR_INVALID_MESSAGE_SIZE), // TODO: remove, wtf do we want with recvmsg errors
	Interrupted_By_Signal                = i32(_TCP_RECV_ERROR_INTERRUPTED_BY_SIGNAL),
	Buffer_Pointer_Outside_Address_Space = i32(_TCP_RECV_ERROR_BUFFER_POINTER_OUTSIDE_ADDRESS_SPACE),
	// Darwin & Linux & Windows:
	Shutdown                             = i32(_TCP_RECV_ERROR_SHUTDOWN),
	Aborted                              = i32(_TCP_RECV_ERROR_ABORTED),
	Host_Unreachable                     = i32(_TCP_RECV_ERROR_HOST_UNREACHABLE),
	// Darwin & Linux:                   
	Connection_Broken                    = i32(_TCP_RECV_ERROR_CONNECTION_BROKEN), // TODO(tetra): Is this error actually possible here?
	Offline                              = i32(_TCP_RECV_ERROR_OFFLINE),
	Interrupted                          = i32(_TCP_RECV_ERROR_INTERRUPTED), // == Interrupted_By_Signal?
	// Windows:
	Network_Subsystem_Failure            = i32(_TCP_RECV_ERROR_NETWORK_SUBSYSTEM_FAILURE),
	Bad_Buffer                           = i32(_TCP_RECV_ERROR_BAD_BUFFER), // == Buffer_Pointer_Outside_Address_Space?
	Keepalive_Failure                    = i32(_TCP_RECV_ERROR_KEEPALIVE_FAILURE),
	Would_Block                          = i32(_TCP_RECV_ERROR_WOULD_BLOCK),
}

UDP_Recv_Error :: enum i32 {
	None,

	// All:
	Not_Socket                           = i32(_UDP_RECV_ERROR_NOT_SOCKET),
	Timeout                              = i32(_UDP_RECV_ERROR_TIMEOUT),
	// All but windows:
	Not_Descriptor                       = i32(_UDP_RECV_ERROR_NOT_DESCRIPTOR),
	// FreeBSD:
	Connection_Closed                    = i32(_UDP_RECV_ERROR_CONNECTION_CLOSED), // TODO(laytan): ??? there is no connection with udp
	Not_Connected                        = i32(_UDP_RECV_ERROR_NOT_CONNECTED), // TODO(laytan): ??? there is no connection with udp
	Full_Table_And_Data_Discarded        = i32(_UDP_RECV_ERROR_FULL_TABLE_AND_PENDING_DATA), // TODO: remove, wtf do we want with recvmsg errors
	Invalid_Message_Size                 = i32(_UDP_RECV_ERROR_INVALID_MESSAGE_SIZE), // TODO: remove, wtf do we want with recvmsg errors
	Interrupted_By_Signal                = i32(_UDP_RECV_ERROR_INTERRUPTED_BY_SIGNAL),
	Buffer_Pointer_Outside_Address_Space = i32(_UDP_RECV_ERROR_BUFFER_POINTER_OUTSIDE_ADDRESS_SPACE),
	// Darwin & Linux & Windows:
	Buffer_Too_Small                     = i32(_UDP_RECV_ERROR_BUFFER_TOO_SMALL),
	Bad_Buffer                           = i32(_UDP_RECV_ERROR_BAD_BUFFER), // == Buffer_Pointer_Outside_Address_Space?
	// Darwin & Linux:
	Interrupted                          = i32(_UDP_RECV_ERROR_INTERRUPTED), // == Interrupted_By_Signal?
	Socket_Not_Bound                     = i32(_UDP_RECV_ERROR_SOCKET_NOT_BOUND),
	// Windows:
	Network_Subsystem_Failure            = i32(_UDP_RECV_ERROR_NETWORK_SUBSYSTEM_FAILURE),
	Aborted                              = i32(_UDP_RECV_ERROR_ABORTED), // TODO(laytan): ?? there is no connection with udp.
	Remote_Not_Listening                 = i32(_UDP_RECV_ERROR_REMOTE_NOT_LISTENING),
	Shutdown                             = i32(_UDP_RECV_ERROR_SHUTDOWN),
	Broadcast_Disabled                   = i32(_UDP_RECV_ERROR_BROADCAST_DISABLED),
	No_Buffer_Space_Available            = i32(_UDP_RECV_ERROR_NO_BUFFER_SPACE_AVAILABLE),
	Would_Block                          = i32(_UDP_RECV_ERROR_WOULD_BLOCK),
	Host_Unreachable                     = i32(_UDP_RECV_ERROR_HOST_UNREACHABLE),
	Offline                              = i32(_UDP_RECV_ERROR_OFFLINE),
	Incorrectly_Configured               = i32(_UDP_RECV_ERROR_INCORRECTLY_CONFIGURED),
	TTL_Expired                          = i32(_UDP_RECV_ERROR_TTL_EXPIRED), // TODO(laytan): ?? ttl on udp?
}

TCP_Send_Error :: enum i32 {
	None,

	// All:
	Connection_Closed,
	Not_Connected,
	No_Buffer_Space_Available,
	Host_Unreachable,
	Not_Socket,
	// Darwin & Linux & Windows:
	Aborted,
	Shutdown,
	Offline,
	Timeout,
	// Darwin & Linux:
	Interrupted,
	// Windows:
	Network_Subsystem_Failure,
	Broadcast_Disabled,
	Bad_Buffer,
	Keepalive_Failure,
	// FreeBSD & Windows:
	Would_Block,
	// FreeBSD:
	Not_Descriptor,
	Broadcast_Status_Mismatch,
	Argument_In_Invalid_Address_Space,
	Message_Size_Breaks_Atomicity,
	Already_Connected,
	ICMP_Unreachable,
	Host_Down,
	Network_Down,
	Jailed_Socket_Tried_To_Escape,
	Cannot_Send_More_Data,
}

UDP_Send_Error :: enum i32 {
	None,

	// All:
	Not_Socket,
	No_Buffer_Space_Available,
	Host_Unreachable,

	// All but Windows:
	Not_Descriptor,

	// Darwin & Linux & Windows:
	Message_Too_Long,
	Bad_Buffer,
	Timeout,

	// Darwin & Linux:
	Network_Unreachable,
	No_Outbound_Ports_Available,
	Interrupted,
	No_Memory_Available,

	// FreeBSD & Windows:
	Would_Block,

	// FreeBSD:
	Connection_Closed, // TODO(laytan): ?? connection in udp:P
	Broadcast_Status_Mismatch,
	Not_Connected, // TODO(laytan): ?? connection in udp:P
	Argument_In_Invalid_Address_Space,
	Message_Size_Breaks_Atomicity,
	Already_Connected, // TODO(laytan): ?? connection in udp:P
	ICMP_Unreachable,
	Host_Down,
	Network_Down,
	Jailed_Socket_Tried_To_Escape,
	Cannot_Send_More_Data,

	// Windows:
	Network_Subsystem_Failure,
	Aborted,
	Remote_Not_Listening,
	Shutdown,
	Broadcast_Disabled,
	Keepalive_Failure,
	// This socket is unidirectional and cannot be used to send any data.
	// TODO: verify possible; decide whether to keep if not
	Receive_Only,
	Cannot_Use_Any_Address,
	Family_Not_Supported_For_This_Socket,
	Offline,
}

Shutdown_Error :: enum i32 {
	None,

	// All:
	Not_Connected,
	Not_Socket,
	Invalid_Manner,
	// Darwin & Linux & Windows:
	Aborted,
	Reset,
	Offline,
	// FreeBSD:
	Not_Descriptor,
}

Socket_Option_Error :: enum i32 {
	None,

	// All:
	Not_Socket,
	// Darwin & Linux:
	Offline,
	// Darwin & Linux & Windows:
	Timeout_When_Keepalive_Set,
	Invalid_Option_For_Socket,
	Reset_When_Keepalive_Set,
	// FreeBSD:
	Not_Descriptor,
	Unknown_Option_For_Level, // == Invalid_Option_For_Socket ?
	Argument_In_Invalid_Address_Space,
	Invalid_Value,
	System_Memory_Allocation_Failed,
	Insufficient_System_Resources,
	// FreeBSD & Windows:
	Value_Out_Of_Range,
	// Windows:
	Linger_Only_Supports_Whole_Seconds,
	Network_Subsystem_Failure,
}

Set_Blocking_Error :: enum i32 {
	None,

	// TODO: linux & darwin

	// FreeBSD:
	Not_Descriptor,
	Wrong_Descriptor,
	// Windows:
	Network_Subsystem_Failure,
	Blocking_Call_In_Progress,
	Not_Socket,

	// TODO: are those errors possible?
	Network_Subsystem_Not_Initialized,
	Invalid_Argument_Pointer,
}
