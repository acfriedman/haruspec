import type { SceneMap } from "#kit";
import { ThreeLines } from "./s01-three-lines";
import { Stamp } from "./s02-stamp";
import { Derived } from "./s03-derived";
import { Amend } from "./s04-amend";
import { Bind } from "./s05-bind";
import { Explore } from "./s06-explore";
import { Continuous } from "./s07-continuous";

export const scenes: SceneMap = {
  "three-lines": ThreeLines,
  stamp: Stamp,
  derived: Derived,
  amend: Amend,
  bind: Bind,
  explore: Explore,
  continuous: Continuous,
};
