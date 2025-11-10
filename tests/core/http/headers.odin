package tests_http

import "core:http"
import "core:testing"

@(test)
header_value_iterator :: proc(t: ^testing.T) {
	cases := [][]string{
		{"hell\rope\r\n!", "hell", " ", "ope", " ", " ", "!"},
		{"hellope!", "hellope!"},
		{"", ""},
	}
	for tcase in cases {
		i := 1
		input := tcase[0]
		for part in http.header_value_iterator(&input) {
			testing.expect_value(t, part, tcase[i])
			i += 1
		}
	}
}
