# Guard example

Run this separate application from the repository root:

```sh
cd examples/guards
gleam run
```

It listens on port **8788**, so it can run beside `examples/simple` on 8787.
The two hard-coded bearer tokens demonstrate the guard flow; they are demo credentials.

```sh
curl -i http://localhost:8788/public/hello                       # 200, public
curl -i http://localhost:8788/public/me                          # 401, endpoint guard
curl -i http://localhost:8788/public/me -H 'Authorization: Bearer member-token' # 200
curl -i http://localhost:8788/account/me                         # 401, controller guard
curl -i http://localhost:8788/account/me -H 'Authorization: Bearer member-token' # 200, Ada
curl -i http://localhost:8788/account/me -H 'Authorization: Bearer admin-token' # 200, Grace
curl -i http://localhost:8788/account/admin/42 -H 'Authorization: Bearer member-token' # 403
curl -i http://localhost:8788/account/admin/42 -H 'Authorization: Bearer admin-token' # 200
curl -i http://localhost:8788/account/admin/nope -H 'Authorization: Bearer admin-token' # 400
```

Or run the same requests as tests, without a server:

```sh
gleam test
```

- `test/guards_test.gleam`: sends every request above through `app()` with `howdy/testing` and checks the status, body and error message of each.
- `src/guards/auth.gleam`: guards return `service.Result(value)`. Authentication returns `CurrentUser`; the admin check returns `Nil`.
- `src/howdy_guards_example.gleam`: `controller.guarded` supplies `ctx.guard` to every handler. `controller.build()` makes it mountable alongside ordinary controllers. `guard.require` adds an endpoint check using Gleam's `use` syntax.
- `src/guards/profile_service.gleam`: takes a typed `CurrentUser` to look up a profile, without receiving HTTP context.

Controller guards run once for each matched request, before the endpoint handler. Endpoint guards run where `guard.require` appears; put them before protected work. The first error stops that chain and becomes the standard service error response. App and controller middleware wrap the guard and can inspect rejection responses.
