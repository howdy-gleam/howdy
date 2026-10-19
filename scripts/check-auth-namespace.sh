#!/bin/sh
# Core reserves the optional packages' module names; BEAM names are global.
set -eu
cd "$(dirname "$0")/.."
for module in src/howdy/auth.gleam src/howdy/auth src/howdy/authorization.gleam src/howdy/database.gleam src/howdy/migration.gleam src/howdy/remote.gleam src/howdy/remote src/howdy/admin.gleam src/howdy/admin src/howdy/mail.gleam src/howdy/mail src/howdy/storage.gleam src/howdy/storage src/howdy/flags.gleam src/howdy/flags src/howdy/jobs.gleam src/howdy/jobs src/howdy/notifications.gleam src/howdy/notifications src/howdy/cache.gleam src/howdy/cache src/howdy/openapi.gleam src/howdy/openapi src/howdy/telemetry.gleam src/howdy/telemetry src/howdy/ui.gleam src/howdy/ui src/howdy/dev.gleam src/howdy/dev; do
  if [ -e "$module" ]; then
    echo "Reserved optional-package namespace collides with core: $module" >&2
    exit 1
  fi
done
