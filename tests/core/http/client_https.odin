#+build !riscv64
package tests_client

import "core:http"
import "core:log"
import "core:nbio"
import "core:testing"
import "core:time"

import ssl_http "vendor:openssl/http"

// TODO: make the CI able to run this test on RISCV, it should be able to run fine, besides that
// the CI now does a static linking trick and this test needs openssl, which is dynamically linked.

@(test)
openssl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Second * 10)

	http.set_client_ssl(ssl_http.client_implementation())

	State :: struct {
		t:      ^testing.T,
		client: http.Client,
	}
	s: State
	s.t = t

	if !http.client_init(&s.client) {
		log.warn("could not initialize http client, probably unsupported target, skipping test")
		return
	}

	http.request(&s.client, http.get("https://www.google.com/", &s, proc(req: http.Client_Request, res: ^http.Client_Response, err: http.Request_Error) {
		s := (^State)(req.user_data)

		ev(s.t, err, nil)
		ev(s.t, res.status, http.Status.OK)

		log.debug("cleaning up")

		http.response_destroy(&s.client, res^)
		http.client_destroy(&s.client)
	}))

	ev(t, nbio.run(), nil)
}

@(test)
one_sync :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Second * 10)

	http.set_client_ssl(ssl_http.client_implementation())

	c: http.Client
	if !http.client_init(&c) {
		log.warn("could not initialize http client, probably unsupported target, skipping test")
		return
	}
	defer {
		http.client_destroy(&c)
		ev(t, nbio.run(), nil)
	}

	res, err := http.sync_request(&c, http.get("https://odin-lang.org"))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, res.status, http.Status.OK)
	testing.expect(t, len(res.body) > 0)

	http.response_destroy(&c, res)
}

@(test)
multi_sync :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Second * 10)

	http.set_client_ssl(ssl_http.client_implementation())

	c: http.Client
	if !http.client_init(&c) {
		log.warn("could not initialize http client, probably unsupported target, skipping test")
		return
	}
	defer {
		http.client_destroy(&c)
		ev(t, nbio.run(), nil)
	}

	responses := http.sync_request(&c, 
		http.get("https://odin-lang.org"),
		http.get("https://odin-lang.org/docs/overview/"),
		http.get("https://odin-lang.org/docs/faq/"),
	)
	testing.expect_value(t, len(responses), 3)
	defer http.responses_destroy(&c, responses)

	for response in responses {
		testing.expect_value(t, response.err, nil)
		testing.expect_value(t, response.res.status, http.Status.OK)
	}
}
