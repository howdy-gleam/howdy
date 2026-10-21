//// The feature flag pages: every flag with its state, one flag's kill
//// switch, rollout, ramp, rules and history, a check of who gets it, and
//// the groups rules can name.

import gleam/http/response.{type Response}
import gleam/int
import gleam/result
import gleam/string
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/flags/flag as flag_pages
import howdy/admin/internal/flags/groups as group_pages
import howdy/admin/internal/flags/pieces
import howdy/admin/internal/layout
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/flags.{type Flags}
import howdy/form.{type Form}
import howdy/service

const actor = "howdy_admin"

pub fn controller(config: Config, features: Flags) -> Controller {
  let act = fn(run) { fn(ctx) { act(config, ctx, run) } }
  controller.new(config.prefix)
  |> controller.get("/flags", fn(ctx) {
    flag_pages.index(config, features, ctx)
  })
  |> controller.get("/flags/flag", fn(ctx) {
    flag_pages.show(config, features, ctx)
  })
  |> controller.post(
    "/flags/flag/kill",
    act(fn(key, _) { flags.kill(features, key, by: actor) }),
  )
  |> controller.post(
    "/flags/flag/revive",
    act(fn(key, _) { flags.revive(features, key, by: actor) }),
  )
  |> controller.post(
    "/flags/flag/allow",
    act(fn(key, form) {
      use target <- result.try(pieces.read_target(config, form))
      flags.allow(features, key, target, by: actor)
    }),
  )
  |> controller.post(
    "/flags/flag/block",
    act(fn(key, form) {
      use target <- result.try(pieces.read_target(config, form))
      flags.block(features, key, target, by: actor)
    }),
  )
  |> controller.post(
    "/flags/flag/unlist",
    act(fn(key, form) {
      use target <- result.try(
        flags.target_from_string(form.value(form, "target"))
        |> result.replace_error(service.Invalid("no such rule")),
      )
      flags.unlist(features, key, target, by: actor)
    }),
  )
  |> controller.post(
    "/flags/flag/forget",
    act(fn(key, _) { flags.forget(features, key, by: actor) }),
  )
  |> controller.post(
    "/flags/flag/undo",
    act(fn(_, form) {
      use id <- result.try(
        int.parse(form.value(form, "change"))
        |> result.replace_error(service.NotFound("no such change")),
      )
      flags.undo(features, change: id, by: actor)
    }),
  )
  |> controller.get("/flags/groups", fn(ctx) {
    group_pages.index(config, features, ctx)
  })
  |> controller.post("/flags/groups", fn(ctx) {
    use form <- form.read(ctx)
    let name = string.trim(form.value(form, "name"))
    case
      flags.create_group(
        features,
        name,
        description: form.value(form, "description"),
        by: actor,
      )
    {
      Ok(Nil) -> layout.redirect(pieces.group_path(config, name))
      Error(error) -> pieces.groups_failure(config, ctx, error)
    }
  })
  |> controller.get("/flags/groups/group", fn(ctx) {
    group_pages.show(config, features, ctx)
  })
  |> controller.post("/flags/groups/group/add", fn(ctx) {
    use name <- pieces.with_group(config, ctx)
    use form <- form.read(ctx)
    let outcome = {
      use member <- result.try(pieces.read_target(config, form))
      flags.add_member(features, name, member, by: actor)
    }
    case outcome {
      Ok(Nil) -> layout.redirect(pieces.group_path(config, name))
      Error(error) -> pieces.groups_failure(config, ctx, error)
    }
  })
  |> controller.post("/flags/groups/group/remove", fn(ctx) {
    use name <- pieces.with_group(config, ctx)
    use form <- form.read(ctx)
    let outcome = {
      use member <- result.try(
        flags.target_from_string(form.value(form, "member"))
        |> result.replace_error(service.Invalid("no such member")),
      )
      flags.remove_member(features, name, member, by: actor)
    }
    case outcome {
      Ok(Nil) -> layout.redirect(pieces.group_path(config, name))
      Error(error) -> pieces.groups_failure(config, ctx, error)
    }
  })
  |> controller.post("/flags/groups/group/delete", fn(ctx) {
    use name <- pieces.with_group(config, ctx)
    case flags.delete_group(features, name, by: actor) {
      Ok(Nil) -> layout.redirect(config.path(config, "/flags/groups"))
      Error(error) -> pieces.groups_failure(config, ctx, error)
    }
  })
}

/// Run a change to the flag the query names, then show the flag again.
fn act(
  config: Config,
  ctx: Context,
  run: fn(String, Form) -> service.Result(Nil),
) -> Response(Content) {
  use key <- pieces.with_key(config, ctx)
  use form <- form.read(ctx)
  case run(key, form) {
    Ok(Nil) -> layout.redirect(pieces.flag_path(config, key))
    Error(error) -> pieces.failure(config, ctx, key, error)
  }
}
