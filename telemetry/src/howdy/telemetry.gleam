//// Switch on OpenTelemetry for a Howdy app.
////
//// Howdy opens spans around requests, database queries, remote calls and
//// email with `howdy/trace`, but they go nowhere until telemetry is
//// started. Adding this package and calling `start` is the opt-in:
////
//// ```gleam
//// import howdy/telemetry
////
//// pub fn main() {
////   let assert Ok(Nil) =
////     telemetry.new("acme-web")
////     |> telemetry.otlp
////     |> telemetry.start
////   ...
//// }
//// ```
////
//// `otlp` sends traces to an OpenTelemetry collector or any backend that
//// takes OTLP over HTTP, such as Grafana Tempo, Honeycomb or Jaeger. It
//// reads the standard `OTEL_EXPORTER_OTLP_*` environment variables, so the
//// endpoint and API keys stay out of the code. For development, `record`
//// keeps recent traces in memory for the admin area to show.
////
//// Until `start` is called nothing is recorded or sent, even though the
//// OpenTelemetry SDK is running. Setting `OTEL_SDK_DISABLED=true` keeps it
//// that way after `start` too. Call `start` before `logging.configure()`
//// only if you do not use `json_logs`, since `logging.configure()` replaces
//// the log formatter.

import gleam/float
import gleam/option.{type Option, None, Some}
import gleam/result
import howdy/telemetry/recorder.{type Recorder}

pub opaque type Config {
  Config(
    service: String,
    attributes: List(#(String, String)),
    exporters: List(Exporter),
    ratio: Option(Float),
    json_logs: Bool,
  )
}

/// Where finished spans go.
type Exporter {
  Otlp(endpoint: Option(String), headers: List(#(String, String)))
  Record(recorder: Recorder)
}

/// Telemetry for the service called `service`, the name traces are filed
/// under in your backend. The `OTEL_SERVICE_NAME` environment variable
/// overrides it. Nothing is exported until you add an exporter with
/// `otlp`, `otlp_to` or `record`.
pub fn new(service: String) -> Config {
  Config(service:, attributes: [], exporters: [], ratio: None, json_logs: False)
}

/// Describe the service with another resource attribute, such as
/// `service.version` or `deployment.environment.name`. Every span carries
/// it. `OTEL_RESOURCE_ATTRIBUTES` adds more without code.
pub fn resource(config: Config, key: String, value: String) -> Config {
  Config(..config, attributes: [#(key, value), ..config.attributes])
}

/// Send spans over OTLP/HTTP, configured by the standard environment
/// variables:
///
/// - `OTEL_EXPORTER_OTLP_ENDPOINT`, such as `https://api.honeycomb.io`.
///   Defaults to `http://localhost:4318`, where a local collector listens.
/// - `OTEL_EXPORTER_OTLP_HEADERS`, such as `x-honeycomb-team=KEY`, for
///   backends that want an API key.
///
/// Spans are sent in batches from a background process, a few seconds
/// apart. Call `flush` before a short-lived program exits.
pub fn otlp(config: Config) -> Config {
  Config(..config, exporters: [Otlp(None, []), ..config.exporters])
}

/// Telemetry for `service` sending spans over OTLP, if the environment names
/// a collector with `OTEL_EXPORTER_OTLP_ENDPOINT` or
/// `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, and `Error(Nil)` otherwise. It
/// lets one build send telemetry where a collector is configured and stay
/// silent everywhere else:
///
/// ```gleam
/// case telemetry.from_env("acme-web") {
///   Ok(config) -> {
///     let assert Ok(Nil) = telemetry.start(config)
///     Nil
///   }
///   Error(Nil) -> Nil
/// }
/// ```
pub fn from_env(service: String) -> Result(Config, Nil) {
  case
    getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
    getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
  {
    Error(Nil), Error(Nil) -> Error(Nil)
    _, _ -> Ok(new(service) |> otlp)
  }
}

@external(erlang, "howdy_telemetry_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

/// Send spans over OTLP/HTTP to `endpoint`, with extra `headers` on every
/// export, instead of reading them from the environment.
pub fn otlp_to(
  config: Config,
  endpoint endpoint: String,
  headers headers: List(#(String, String)),
) -> Config {
  Config(..config, exporters: [
    Otlp(Some(endpoint), headers),
    ..config.exporters
  ])
}

/// Keep finished spans and log lines in `recorder` for the dev admin to
/// show. Meant for development: it holds the last traces in memory.
pub fn record(config: Config, recorder: Recorder) -> Config {
  Config(..config, exporters: [Record(recorder), ..config.exporters])
}

/// Record only a share of traces, between `0.0` and `1.0`, to keep costs
/// down on a busy site. Everything is recorded by default. A request that
/// arrives from another traced service keeps that service's decision, so
/// its trace is either recorded throughout or not at all. The
/// `OTEL_TRACES_SAMPLER` variables override this.
pub fn sample(config: Config, ratio: Float) -> Config {
  Config(..config, ratio: Some(float.clamp(ratio, 0.0, 1.0)))
}

/// Write log lines as JSON objects, one per line, carrying the trace and
/// span ids of the request that logged them, for log collectors that link
/// logs to traces. Call `start` after `logging.configure()`, which sets its
/// own formatter.
pub fn json_logs(config: Config) -> Config {
  Config(..config, json_logs: True)
}

/// Start recording and exporting. Call it once, early in `main`. Calling it
/// again replaces the previous configuration. Fails only if the
/// OpenTelemetry SDK application is not running.
///
/// Warnings and errors logged inside a span are added to it as `log`
/// events, and crashes of processes outside any span are recorded as
/// `process crash` spans.
pub fn start(config: Config) -> Result(Nil, String) {
  let Config(service:, attributes:, exporters:, ratio:, json_logs:) = config
  do_start(service, attributes, exporters, ratio, json_logs)
  |> result.map(fn(_) { Nil })
}

/// Stop recording and exporting, as if `start` had never been called.
@external(erlang, "howdy_telemetry_ffi", "idle")
pub fn stop() -> Nil

/// Export every finished span now, rather than with the next batch. Call it
/// before a script or task exits.
@external(erlang, "howdy_telemetry_ffi", "flush")
pub fn flush() -> Nil

@external(erlang, "howdy_telemetry_ffi", "start")
fn do_start(
  service: String,
  attributes: List(#(String, String)),
  exporters: List(Exporter),
  ratio: Option(Float),
  json_logs: Bool,
) -> Result(Nil, String)
