#+build !darwin
#+build !windows
#+build !linux
package net

import "core:c"

Create_Socket_Error :: enum c.int {
	None,
}

Dial_Error :: enum c.int {
	None,
}

Bind_Error :: enum c.int {
	None,
}

Listen_Error :: enum c.int {
	None,
}

Accept_Error :: enum c.int {
	None,
}

TCP_Recv_Error :: enum c.int {
	None,
}

UDP_Recv_Error :: enum c.int {
	None,
}

TCP_Send_Error :: enum c.int {
	None,
}

UDP_Send_Error :: enum c.int {
	None,
}

Shutdown_Error :: enum c.int {
	None,
}

Socket_Option_Error :: enum c.int {
	None,
}

Set_Blocking_Error :: enum c.int {
	None,
}
