//// The auth pages: users and groups, and signing in as a user.

import howdy/admin/internal/accounts/groups as group_pages
import howdy/admin/internal/accounts/users as user_pages
import howdy/admin/internal/config.{type Config}
import howdy/auth.{type Auth}
import howdy/authorization
import howdy/controller.{type Controller}

pub fn controller(config: Config, identity: Auth) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/users", fn(ctx) {
    user_pages.user_index(config, identity, ctx)
  })
  |> controller.post("/users", fn(ctx) {
    user_pages.user_create(config, identity, ctx)
  })
  |> controller.get("/users/:id", fn(ctx) {
    user_pages.user_show(config, identity, ctx)
  })
  |> controller.post("/users/:id/suspend", fn(ctx) {
    user_pages.user_action(config, ctx, fn(id) {
      auth.suspend(identity, id, by: config.actor)
    })
  })
  |> controller.post("/users/:id/resume", fn(ctx) {
    user_pages.user_action(config, ctx, fn(id) {
      auth.resume(identity, id, by: config.actor)
    })
  })
  |> controller.post("/users/:id/revoke", fn(ctx) {
    user_pages.user_action(config, ctx, fn(id) {
      user_pages.forget_token(identity, id)
      auth.revoke_sessions(identity, id, by: config.actor)
    })
  })
  |> controller.post("/users/:id/move", fn(ctx) {
    user_pages.user_move(config, identity, ctx)
  })
  |> controller.post("/users/:id/impersonate", fn(ctx) {
    user_pages.impersonate(config, identity, ctx)
  })
  |> controller.post("/users/:id/delete", fn(ctx) {
    user_pages.user_delete(config, identity, ctx)
  })
  |> controller.post("/users/:id/sessions/revoke", fn(ctx) {
    user_pages.session_revoke(config, identity, ctx)
  })
  |> controller.post("/users/:id/roles/assign", fn(ctx) {
    user_pages.role_change(config, ctx, fn(access, id, scope, role) {
      authorization.assign(access, id, role, scope, by: config.actor)
    })
  })
  |> controller.post("/users/:id/roles/revoke", fn(ctx) {
    user_pages.role_change(config, ctx, fn(access, id, scope, role) {
      authorization.revoke(access, id, role, scope, by: config.actor)
    })
  })
  |> controller.get("/groups", fn(ctx) {
    group_pages.group_index(config, identity, ctx)
  })
  |> controller.post("/groups", fn(ctx) {
    group_pages.group_create(config, identity, ctx)
  })
  |> controller.get("/groups/:id", fn(ctx) {
    group_pages.group_show(config, identity, ctx)
  })
  |> controller.post("/groups/:id/rename", fn(ctx) {
    group_pages.group_rename(config, identity, ctx)
  })
  |> controller.post("/groups/:id/delete", fn(ctx) {
    group_pages.group_delete(config, identity, ctx)
  })
}
