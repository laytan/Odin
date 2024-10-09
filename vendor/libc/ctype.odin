package odin_libc

@(require, linkage="strong", link_name="isdigit")
isdigit :: proc "c" (c: i32) -> i32 {
	switch c {
	case '0'..='9': return 1
	case:           return 0
	}
}

@(require, linkage="strong", link_name="isblank")
isblank :: proc "c" (c: i32) -> i32 {
	switch c {
	case '\t', ' ': return 1
	case:           return 0
	}
}
