//// Invitation-only workspaces with per-workspace roles.
////
//// Each workspace is an auth **group**. Nobody can register: trusted code
//// creates a workspace and its owner, and owners invite members, who then
//// sign in with an emailed token. Roles are defined and checked per workspace
//// (`access.Organization(group_id)`), so an owner of one workspace has no
//// power in another. Small per-user and per-workspace facts live in auth
//// **fields**; anything relational belongs in your own tables.
////
////     gleam run -m migrate
////     gleam run -m flows/multi_tenant
////
//// Startup creates the "acme" workspace owned by owner@acme.test. Sign in as
//// that address at http://localhost:8787/auth/login with the printed token,
//// then:
////
////     GET  /workspace                 the workspace, its plan, your profile
////     GET  /workspace/members         needs members.read
////     POST /workspace/members         {"email": ...}; needs members.invite
////     POST /workspace/profile         {"display_name": ...}; your own profile

import database
import demo
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/field.{type Field}
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/user.{type Actor, type User}
import howdy/auth/users
import howdy/authorization as access
import howdy/body
import howdy/controller
import howdy/guard
import howdy/service

pub const database_file = "multi_tenant.sqlite"

pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
) -> #(auth.Auth, access.Authorization) {
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  // Many groups, and each address belongs to exactly one of them. The mode
  // is recorded in the database; see `group.AccountPerGroup` for letting one
  // address hold a separate account in each workspace.
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  // Note what is missing: `auth.allow_registration`. Only invited (provisioned)
  // addresses can sign in.
  let assert Ok(permissions) = access.new(db)
  #(identity, permissions)
}

// --- Fields ------------------------------------------------------------------

/// A workspace fact. Declared once and used to both write and read.
pub fn plan() -> Field(String) {
  field.text("plan")
  |> field.check(fn(plan) {
    case plan {
      "free" | "team" -> Ok(Nil)
      _ -> Error("plan must be free or team")
    }
  })
}

/// A user fact, unique among the members of one workspace.
pub fn display_name() -> Field(String) {
  field.text("display_name")
  |> field.unique_in_group
  |> field.check(fn(name) {
    case string.length(name) {
      n if n >= 2 && n <= 40 -> Ok(Nil)
      _ -> Error("display name must be 2 to 40 characters")
    }
  })
}

// --- Trusted operations -----------------------------------------------------

const owner_permissions = ["members.read", "members.invite"]

const member_permissions = ["members.read"]

/// Operator code, never a public route: create a workspace, its roles and its
/// first owner. Each step is its own transaction, so a failure part-way leaves
/// what came before; rerunning refuses at the first step with `Conflict`.
pub fn create_workspace(
  identity: auth.Auth,
  permissions: access.Authorization,
  id id: String,
  name name: String,
  owner email: String,
  by actor: Actor,
) -> service.Result(User) {
  let scope = access.Organization(id)
  use _ <- result.try(groups.create_with(
    identity,
    id:,
    name:,
    fields: [field.set(plan(), "free")],
    by: actor,
  ))
  use _ <- result.try(access.define_role(
    permissions,
    scope,
    "owner",
    owner_permissions,
    by: actor,
  ))
  use _ <- result.try(access.define_role(
    permissions,
    scope,
    "member",
    member_permissions,
    by: actor,
  ))
  invite(identity, permissions, id, email, "owner", by: actor)
}

/// Create the account without emailing anything; the invitee proves the
/// address is theirs by signing in. `in_group` picks the workspace.
fn invite(
  identity: auth.Auth,
  permissions: access.Authorization,
  workspace: String,
  email: String,
  role: String,
  by actor: Actor,
) -> service.Result(User) {
  use member <- result.try(auth.provision(
    auth.in_group(identity, workspace),
    email,
    by: actor,
  ))
  use _ <- result.map(access.assign(
    permissions,
    member.id,
    role,
    access.Organization(workspace),
    by: actor,
  ))
  member
}

// --- HTTP --------------------------------------------------------------------

pub fn app(
  identity: auth.Auth,
  permissions: access.Authorization,
) -> howdy.App {
  // A signed-in user's workspace is `ctx.guard.user.group_id`, which auth
  // verified. Never take it from the request: that is only a claim.
  let scope = fn(ctx: controller.GuardedContext(user.Principal)) {
    access.Organization(ctx.guard.user.group_id)
  }
  let workspace =
    controller.guarded("/workspace", auth.required(identity))
    |> controller.get("/", fn(ctx) {
      let id = ctx.guard.user.group_id
      {
        use found <- result.try(groups.get(identity, id))
        use workspace_fields <- result.try(groups.fields(identity, id))
        use own <- result.map(users.fields(identity, ctx.guard.user.id))
        json.object([
          #("workspace", group.to_json(found)),
          #(
            "plan",
            json.string(
              field.get(workspace_fields, plan()) |> result.unwrap("free"),
            ),
          ),
          #(
            "display_name",
            json.string(
              field.get(own, display_name())
              |> result.unwrap(ctx.guard.user.email),
            ),
          ),
        ])
      }
      |> service.respond(ctx, fn(body) { body })
    })
    |> controller.get("/members", fn(ctx) {
      use _ <- guard.require(
        ctx,
        access.require_permission(permissions, "members.read", scope(ctx)),
      )
      groups.members(identity, ctx.guard.user.group_id)
      |> service.respond(ctx, json.array(_, user.to_json))
    })
    |> controller.post("/members", fn(ctx) {
      use _ <- guard.require(
        ctx,
        access.require_permission(permissions, "members.invite", scope(ctx)),
      )
      use email <- body.json(ctx, decode.at(["email"], decode.string))
      invite(
        identity,
        permissions,
        ctx.guard.user.group_id,
        email,
        "member",
        by: user.Acting(ctx.guard),
      )
      |> service.created(ctx, user.to_json)
    })
    // Self-service: the application decides a user may edit their own
    // profile, then calls the privileged `users.update` on their behalf.
    |> controller.post("/profile", fn(ctx) {
      use name <- body.json(ctx, decode.at(["display_name"], decode.string))
      users.update(
        identity,
        ctx.guard.user.id,
        [field.set(display_name(), string.trim(name))],
        by: user.Acting(ctx.guard),
      )
      |> service.respond(ctx, user.to_json)
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(workspace)
}

pub fn main() {
  let db = database.open(database_file)
  let #(identity, permissions) = configure(db, demo.print_email)
  case
    create_workspace(
      identity,
      permissions,
      id: "acme",
      name: "Acme",
      owner: "owner@acme.test",
      by: user.System,
    )
  {
    Ok(_) -> io.println("Created the acme workspace, owned by owner@acme.test.")
    Error(service.Conflict(_)) -> Nil
    Error(error) -> panic as service.message(error)
  }
  app(identity, permissions) |> demo.serve
}
