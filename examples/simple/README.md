# howdy example

A minimal application showing how to set up howdy with a single controller.

```sh
cd examples/simple
gleam run
```

It listens on 127.0.0.1:8787. Then in another terminal:

```sh
curl http://localhost:8787/                 # index.html served from priv/public
curl -i http://localhost:8787/style.css
curl http://localhost:8787/user/all
curl http://localhost:8787/user/2
curl -X POST http://localhost:8787/user -d '{"name":"Linus","email":"linus@example.com","age":28}'
curl -i -X DELETE http://localhost:8787/user/2                       # 401 without the key
curl -i -X DELETE http://localhost:8787/user/2 -H 'x-api-key: secret'
curl -i -X POST http://localhost:8787/user -d '{"name":" ","email":"nope","age":5}'   # 422 listing every field
curl -i -X POST http://localhost:8787/user -d '{"name":"Ada","email":"ada@example.com","age":36}' # 422 from the service
curl -i http://localhost:8787/user/abc                       # 400 from param.int
curl -i -X PUT http://localhost:8787/user/all                # 405 with an Allow header
for i in 1 2 3 4; do curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8787/user -H 'x-api-key: secret' -d '{"name":"A","email":"a@b.co","age":20}'; done   # 3 x 201 then 429
```

Or run the same requests as tests, without a server:

```sh
gleam test
```

- `src/howdy_example.gleam` builds the app from its controllers in `app()` and starts ewe in `main`.
- `test/user_controller_test.gleam` sends every request above through `app()` with `howdy/testing` and checks the responses, including the rate limits.
- `src/user/controller.gleam` defines the `/user` routes. Each handler is three lines: extract, call the service, respond.
- `src/user/user_service.gleam` holds the logic and returns `service.Result` values, never HTTP.
- `src/user/user.gleam` is the type with its JSON codecs and the validator. Input and validated types are separate, so the service signature proves validation ran.
- Rate limits: a fixed window of 100 a minute per IP on the whole app, and a token bucket of 3 then one a second per API key on creating users. Both are set up where the app is built.
- Middleware is applied at each level: the built-in `howdy/logger.log` on the app, `src/middleware/powered_by` on the controller, and `src/middleware/api_key` on the delete route only.
