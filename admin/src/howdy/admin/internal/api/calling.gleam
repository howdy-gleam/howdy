//// Calling an endpoint: the request built from the form, sent through the
//// app as nobody or as a user, and the same request as a curl command.

import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import howdy/admin/internal/api_spec.{
  type Document, type Operation, type Parameter, ApiKey, Bearer,
}
import howdy/admin/internal/config.{type Api, type Config}
import howdy/auth.{type Auth}
import howdy/auth/secret
import howdy/auth/users
import howdy/content.{type Content}
import howdy/context.{type Body}
import howdy/controller.{type Context}
import howdy/form
import howdy/service
import howdy/testing

pub fn field_name(parameter: Parameter) -> String {
  parameter.location <> ":" <> parameter.name
}

pub type Outcome {
  Outcome(
    status: Int,
    headers: List(#(String, String)),
    body: String,
    milliseconds: Float,
    as_user: Option(String),
    curl: String,
  )
  Failed(service.Error)
}

pub fn call(
  config: Config,
  api: Api,
  ctx: Context,
  document: Document,
  operation: Operation,
  fields: form.Form,
) -> Outcome {
  let base = build_request(document, operation, fields)
  let as_user = case config.identity, form.value(fields, "as") {
    Some(identity), id if id != "" -> Some(#(identity, id))
    _, _ -> None
  }
  let result = case as_user {
    None -> Ok(#(base, send(api, base)))
    Some(#(identity, id)) -> {
      use #(token, cached) <- result.try(token_for(identity, id, fresh: False))
      let req = with_bearer(base, token)
      let res = send(api, req)
      case res.1.status, cached {
        401, True -> {
          // The kept token no longer works: forget it before trying for
          // another, so it is gone even if that fails.
          forget_token(identity, id)
          use #(token, _) <- result.try(token_for(identity, id, fresh: True))
          let req = with_bearer(base, token)
          Ok(#(req, send(api, req)))
        }
        _, _ -> Ok(#(req, res))
      }
    }
  }
  case result {
    Error(error) -> Failed(error)
    Ok(#(req, #(milliseconds, res))) ->
      Outcome(
        status: res.status,
        headers: res.headers,
        body: body_text(res),
        milliseconds:,
        as_user: option.map(as_user, fn(pair) { email_of(pair.0, pair.1) }),
        curl: curl(ctx, req, form.value(fields, "body"), operation),
      )
  }
}

fn email_of(identity: Auth, id: String) -> String {
  users.get(identity, id)
  |> result.map(fn(account) { account.email })
  |> result.unwrap(id)
}

fn build_request(
  document: Document,
  operation: Operation,
  fields: form.Form,
) -> Request(Body) {
  let value = fn(parameter) { form.value(fields, field_name(parameter)) }
  let path =
    list.fold(operation.parameters, operation.path, fn(path, parameter) {
      case parameter.location {
        "path" ->
          string.replace(
            path,
            "{" <> parameter.name <> "}",
            uri.percent_encode(value(parameter)),
          )
        _ -> path
      }
    })
  let pairs =
    list.flat_map(operation.parameters, fn(parameter) {
      case parameter.location, value(parameter) {
        "query", "" -> []
        "query", text ->
          case api_spec.is_array(parameter.schema) {
            True ->
              string.split(text, ",")
              |> list.map(string.trim)
              |> list.map(fn(item) { #(parameter.name, item) })
            False -> [#(parameter.name, text)]
          }
        _, _ -> []
      }
    })
  let method =
    http.parse_method(string.uppercase(operation.method))
    |> result.unwrap(http.Get)
  let req =
    testing.request(method, path)
    |> testing.header("accept", api_spec.accept_for(operation))
  let req = case pairs {
    [] -> req
    _ -> testing.query(req, pairs)
  }
  let req =
    list.fold(operation.parameters, req, fn(req, parameter) {
      case parameter.location, value(parameter) {
        _, "" -> req
        "header", text -> testing.header(req, parameter.name, text)
        "cookie", text -> request.set_cookie(req, parameter.name, text)
        _, _ -> req
      }
    })
  let req =
    list.fold(api_spec.security_of(document, operation), req, fn(req, name) {
      case
        list.key_find(document.schemes, name),
        form.value(fields, "scheme:" <> name)
      {
        _, "" | Error(Nil), _ -> req
        Ok(Bearer), token ->
          testing.header(req, "authorization", "Bearer " <> token)
        Ok(ApiKey(location: "header", name: header)), key ->
          testing.header(req, header, key)
        Ok(ApiKey(location: "cookie", name: cookie)), key ->
          request.set_cookie(req, cookie, key)
        Ok(ApiKey(location: "query", name: parameter)), key ->
          request.set_query(
            req,
            list.append(request.get_query(req) |> result.unwrap([]), [
              #(parameter, key),
            ]),
          )
        Ok(_), _ -> req
      }
    })
  case operation.body, form.value(fields, "body") {
    Some(_), body if body != "" ->
      req
      |> testing.text_body(body)
      |> testing.header("content-type", "application/json")
    _, _ -> req
  }
}

fn with_bearer(req: Request(Body), token: String) -> Request(Body) {
  testing.header(req, "authorization", "Bearer " <> token)
}

/// Run a request through the app, timing it.
fn send(api: Api, req: Request(Body)) -> #(Float, Response(Content)) {
  let started = timestamp.system_time()
  let res = testing.send(req, api.app)
  let taken =
    timestamp.difference(started, timestamp.system_time())
    |> duration.to_seconds
  #(taken *. 1000.0, res)
}

/// A token for `user_id`: the one kept from an earlier call, unless `fresh`,
/// or a new impersonated session's. Also says whether it was kept. Tokens
/// are kept per `Auth`, so an admin over two auths never sends one's token
/// to the other; the accounts pages drop a user's token when they revoke
/// their sessions or delete them.
fn token_for(
  identity: Auth,
  user_id: String,
  fresh fresh: Bool,
) -> Result(#(String, Bool), service.Error) {
  case fresh, cached_token(identity, user_id) {
    False, Ok(token) -> Ok(#(token, True))
    _, _ -> {
      use session <- result.map(auth.impersonate(
        identity,
        user_id,
        by: config.actor,
      ))
      let token = secret.reveal(session.token)
      cache_token(identity, user_id, token)
      #(token, False)
    }
  }
}

@external(erlang, "howdy_admin_ffi", "cached_token")
fn cached_token(identity: Auth, user_id: String) -> Result(String, Nil)

@external(erlang, "howdy_admin_ffi", "cache_token")
fn cache_token(identity: Auth, user_id: String, token: String) -> Nil

@external(erlang, "howdy_admin_ffi", "forget_token")
fn forget_token(identity: Auth, user_id: String) -> Nil

fn body_text(res: Response(Content)) -> String {
  case res.body {
    content.Text(text) -> text
    content.Empty -> ""
    content.Bytes(tree) -> {
      let bits = bytes_tree.to_bit_array(tree)
      case bit_array.to_string(bits) {
        Ok(text) -> text
        Error(Nil) ->
          "(" <> int.to_string(bit_array.byte_size(bits)) <> " bytes of binary)"
      }
    }
    content.Native(_) -> "(a file or streamed body, which cannot be shown here)"
  }
}

/// The same request as a curl command against this server.
fn curl(
  ctx: Context,
  req: Request(Body),
  body: String,
  operation: Operation,
) -> String {
  let origin =
    "http://"
    <> ctx.request.host
    <> case ctx.request.port {
      Some(port) -> ":" <> int.to_string(port)
      None -> ""
    }
  let url =
    origin
    <> req.path
    <> case req.query {
      Some(query) -> "?" <> query
      None -> ""
    }
  let headers =
    req.headers
    |> list.filter(fn(header) { header.0 != "host" })
    |> list.map(fn(header) {
      " \\\n  -H " <> shell(header.0 <> ": " <> header.1)
    })
  let data = case operation.body, body {
    Some(_), body if body != "" -> [" \\\n  -d " <> shell(body)]
    _, _ -> []
  }
  "curl -X "
  <> string.uppercase(operation.method)
  <> " "
  <> shell(url)
  <> string.concat(headers)
  <> string.concat(data)
}

fn shell(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}
