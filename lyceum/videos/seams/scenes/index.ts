import type { SceneMap } from "#kit";
import { ColdOpen } from "./s01-cold-open";
import { Boundary } from "./s02-boundary";
import { Initializer } from "./s03-initializer";
import { Values } from "./s04-values";
import { Cassette } from "./s05-cassette";
import { Threads } from "./s06-threads";
import { OverridesNothing } from "./s07-overrides-nothing";
import { Recap } from "./s08-recap";

export const scenes: SceneMap = {
  "cold-open": ColdOpen,
  boundary: Boundary,
  initializer: Initializer,
  values: Values,
  cassette: Cassette,
  threads: Threads,
  "overrides-nothing": OverridesNothing,
  recap: Recap,
};
