package odin_libc

import "core:testing"

@(test)
test_sscanf :: proc(t: ^testing.T) {
	a, b: [100]byte
	x, y, z, u, v: i32

	as := cstring(raw_data(a[:]))
	bs := cstring(raw_data(b[:]))

	ev :: testing.expect_value

	res := osscanf("hello, world\n", "%s %s", &a, &b)
	ev(t, res, 2)
	ev(t, as, "hello,")
	ev(t, bs, "world")

	// res = osscanf("hello, world\n", "%[hel]%s", &a, &b)
	// ev(t, res, 2)
	// ev(t, as, "hell")
	// ev(t, bs, "o,")
	//
	// res = osscanf("hello, world\n", "%[hel] %s", &a, &b)
	// ev(t, res, 2)
	// ev(t, as, "hell")
	// ev(t, bs, "o,")

	a[8] = 'X'
	a[9] = 0
	res = osscanf("hello, world\n", "%8c%8c", &a, &b)
	ev(t, res, 1)
	ev(t, as, "hello, wX")

	// res = osscanf("56789 0123 56a72", "%2d%d%*d %[0123456789]\n", &x, &y, &a)
	// ev(t, res, 3)
	// ev(t, x, 56)
	// ev(t, y, 789)
	// ev(t, as, "56")

	res = osscanf("011 0x100 11 0x100 100", "%i %i %o %x %x\n", &x, &y, &z, &u, &v)
	ev(t, res, 5)
	ev(t, x, 9)
	ev(t, y, 256)
	ev(t, z, 9)
	ev(t, u, 256)
	ev(t, v, 256)

	res = osscanf("20 xyz", "%d %d\n", &x, &y)
	ev(t, res, 1)
	ev(t, x, 20)

	res = osscanf("xyz", "%d %d\n", &x, &y)
	ev(t, res, 0)

	res = osscanf("", "%d %d\n", &x, &y)
	ev(t, res, -1)

	res = osscanf(" 12345 6", "%2d%d%d", &x, &y, &z)
	ev(t, res, 3)
	ev(t, x, 12)
	ev(t, y, 345)
	ev(t, z, 6)

	res = osscanf(" 0x12 0x34", "%5i%2i", &x, &y)
	ev(t, res, 1)
	ev(t, x, 0x12)

	testf :: proc(t: ^testing.T, x: f64, xexpr := #caller_expression(x), loc := #caller_location) {
		cexpr := strings.clone_to_cstring(xexpr)
		d: f64
		res := osscanf(cexpr, "%lf", &d)
		delete(cexpr)
		ev(t, res, 1, loc)
		ev(t, d, x, loc)
	}

	testf(t, 123)
	testf(t, 123.0)
	testf(t, 123.0e+0)
	testf(t, 123.0e+4)
	testf(t, 1.234e1234)
	testf(t, 1.234e-1234)
	testf(t, 1.234e56789)
	testf(t, -0.5)
	testf(t, 0.1)
	testf(t, 0.2)
	testf(t, 0.1e-10)

	d: f64

	res = osscanf("10e", "%lf", &d)
	ev(t, res, 0)

	res = osscanf("", "%lf\n", &d)
	ev(t, res, -1)

	a[1] = 'a'
	res = osscanf("bb", "%c", &a)
	ev(t, res, 1)
	ev(t, a[0], 'b')
	ev(t, a[1], 'a')

	res = osscanf("aa", "%s%n", &a, &x)
	ev(t, res, 1)
	ev(t, as, "aa")
	ev(t, x, 2)
	
	// res = osscanf("", "a")
	// ev(t, res, EOF)
}
