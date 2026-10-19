import howdy/jobs/cron

// 2026-10-19 was a Monday.
const monday_noon = 1_792_411_200_000

const saturday_noon = 1_792_843_200_000

const hour = 3_600_000

const day = 86_400_000

fn next(schedule: String, after: Int) -> Int {
  let assert Ok(parsed) = cron.parse(schedule)
  let assert Ok(next) = cron.next(parsed, after:)
  next
}

pub fn daily_at_a_fixed_time_test() {
  assert next("0 3 * * *", monday_noon) == monday_noon + 15 * hour
}

pub fn next_is_strictly_after_test() {
  let three = monday_noon + 15 * hour
  assert next("0 3 * * *", three) == three + day
  assert next("0 3 * * *", three - 1) == three
}

pub fn steps_ranges_and_weekday_names_test() {
  let schedule = "*/15 9-17 * * mon-fri"
  assert next(schedule, monday_noon + 7 * 60_000) == monday_noon + 15 * 60_000
  // Saturday noon: next is Monday at nine.
  assert next(schedule, saturday_noon) == saturday_noon + 2 * day - 3 * hour
}

pub fn either_day_when_both_are_restricted_test() {
  let schedule = "0 0 1 * mon"
  // The Monday comes first...
  let monday = saturday_noon + day + 12 * hour
  assert next(schedule, saturday_noon) == monday
  // ...then the first of November, a Sunday.
  assert next(schedule, monday) == monday + 6 * day
}

pub fn seven_is_sunday_test() {
  assert next("0 0 * * 7", saturday_noon) == saturday_noon + 12 * hour
  assert next("0 0 * * sun", saturday_noon) == saturday_noon + 12 * hour
}

pub fn shorthands_test() {
  assert next("@daily", monday_noon) == monday_noon + 12 * hour
  assert next("@hourly", monday_noon) == monday_noon + hour
  assert next("@weekly", monday_noon) == monday_noon + 5 * day + 12 * hour
  // 2027-01-01.
  assert next("@yearly", monday_noon) == 1_798_761_600_000
}

pub fn lists_and_offset_steps_test() {
  assert next("5,35 * * * *", monday_noon) == monday_noon + 5 * 60_000
  assert next("10/20 * * * *", monday_noon + 11 * 60_000)
    == monday_noon + 30 * 60_000
  assert next("0 0 29 2 *", monday_noon) == 1_835_395_200_000
}

pub fn to_string_keeps_the_source_test() {
  let assert Ok(parsed) = cron.parse("  0 3 * * * ")
  assert cron.to_string(parsed) == "0 3 * * *"
}

pub fn refuses_bad_schedules_test() {
  let assert Error(_) = cron.parse("60 * * * *")
  let assert Error(_) = cron.parse("* * *")
  let assert Error(_) = cron.parse("5-1 * * * *")
  let assert Error(_) = cron.parse("*/0 * * * *")
  let assert Error(_) = cron.parse("0 0 * * funday")
  let assert Error(_) = cron.parse("0 0 0 * *")
  let assert Error(message) = cron.parse("0 0 30 2 *")
  assert message == "the schedule never comes round: 0 0 30 2 *"
}
