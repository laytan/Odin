// Interaction with the command line interface (`CLI`) of the system.
package terminal

/*
This describes the range of colors that a terminal is capable of supporting.
*/
Color_Depth :: enum {
	None,       // No color support
	Three_Bit,  // 8 colors
	Four_Bit,   // 16 colors
	Eight_Bit,  // 256 colors
	True_Color, // 24-bit true color
}

/*
Returns true if the `File` is attached to a terminal.

This is normally true for `os.stdout` and `os.stderr` unless they are
redirected to a file.
*/
@(require_results)
is_terminal :: proc(f: $T) -> bool {
	return _is_terminal(f)
}

/*
This is true if the terminal is accepting any form of colored text output.
*/
color_enabled: bool

/*
This value reports the color depth support as reported by the terminal at the
start of the program.
*/
color_depth: Color_Depth

Termination_Handler :: #type proc "contextless" (user_data: rawptr) -> bool

/*
Sets a termination handler to handle CTRL+C like signals.

Set handler to `nil` to remove the custom handler.

The given handler must be signal-safe.

Returns `false` on error or when a handler has already been set.
*/
set_termination_handler :: proc(handler: Termination_Handler, user_data: rawptr) -> bool {
	return _set_termination_handler(handler, user_data)
}
