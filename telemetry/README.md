# howdy_telemetry

OpenTelemetry for [howdy](https://github.com/mikeyjones/howdy/blob/v2.1.1/README.md) apps. Howdy opens spans with
`howdy/trace` around requests, database queries, remote calls, email and
sign-in; this package is what sends them somewhere. Without it, or until
`telemetry.start` is called, nothing is recorded or sent.

```sh
gleam add howdy_telemetry@2
```

## Production

```gleam
import howdy/telemetry

let assert Ok(Nil) =
  telemetry.new("acme-web")
  |> telemetry.otlp
  |> telemetry.sample(0.25)
  |> telemetry.start
```

`otlp` sends spans over OTLP/HTTP to `OTEL_EXPORTER_OTLP_ENDPOINT`
(`http://localhost:4318` by default) with `OTEL_EXPORTER_OTLP_HEADERS`, so
it works with an OpenTelemetry collector, Grafana Tempo, Honeycomb, Jaeger
and the rest. `telemetry.from_env(service)` gives a configuration only when
an endpoint is set. `json_logs` writes logs as JSON with trace ids.

## Development

```gleam
let recorder = recorder.new(keep: 200)
let assert Ok(Nil) =
  telemetry.new("acme-web") |> telemetry.record(recorder) |> telemetry.start
admin.new() |> admin.telemetry(recorder)
```

The [admin](https://github.com/mikeyjones/howdy/blob/v2.1.1/admin/README.md) then shows each request as a timeline of
its queries, calls, emails and logs, and points out statements that run
once per row.

## How it works

The OpenTelemetry SDK is an OTP application, so it starts when the app
boots, with defaults that would export to `localhost:4318`. This package's
own application replaces that at boot with the API's no-op tracer, so
installing it changes nothing; `start` then installs a tracer provider
built from the configuration. The recorder is a span processor that keeps
finished spans in ETS tables.

See the [docs](https://github.com/mikeyjones/howdy/blob/v2.1.1/docs/telemetry/overview.djot) for more.
