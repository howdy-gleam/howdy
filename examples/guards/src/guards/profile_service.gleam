//// Application logic takes the authenticated identity, without HTTP context.

import gleam/json
import guards/auth.{type CurrentUser}
import howdy/service

pub type Profile {
  Profile(id: Int, name: String)
}

pub fn find(user: CurrentUser) -> service.Result(Profile) {
  case user.id {
    1 -> Ok(Profile(1, "Ada"))
    2 -> Ok(Profile(2, "Grace"))
    _ -> Error(service.NotFound("profile"))
  }
}

pub fn to_json(profile: Profile) -> json.Json {
  json.object([
    #("id", json.int(profile.id)),
    #("name", json.string(profile.name)),
  ])
}
