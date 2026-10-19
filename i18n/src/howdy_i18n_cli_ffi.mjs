import { Ok, Error } from "./gleam.mjs";
import { execFileSync } from "node:child_process";

export function halt(code) {
  process.exit(code);
}

export function format(path) {
  try {
    execFileSync("gleam", ["format", path], { stdio: "ignore" });
    return new Ok(undefined);
  } catch {
    return new Error(undefined);
  }
}
