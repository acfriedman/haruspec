import type { SceneMap } from "#kit";
import { ColdOpen } from "./s01-cold-open";
import { FourVerdicts } from "./s02-four-verdicts";
import { Qualification } from "./s03-qualification";
import { Diverged } from "./s04-diverged";
import { CannotVerify } from "./s05-cannot-verify";
import { Unstable } from "./s06-unstable";
import { Comparison } from "./s07-comparison";
import { Intent } from "./s08-intent";

export const scenes: SceneMap = {
  "cold-open": ColdOpen,
  "four-verdicts": FourVerdicts,
  qualification: Qualification,
  diverged: Diverged,
  "cannot-verify": CannotVerify,
  unstable: Unstable,
  comparison: Comparison,
  intent: Intent,
};
