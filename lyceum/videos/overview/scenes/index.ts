import type { SceneMap } from "#kit";
import { ColdOpen } from "./s01-cold-open";
import { TheIdea } from "./s02-the-idea";
import { TwoShapes } from "./s03-two-shapes";
import { AtAGlance } from "./s04-at-a-glance";
import { Diverged } from "./s05-diverged";
import { FourVerdicts } from "./s06-four-verdicts";
import { GettingStarted } from "./s07-getting-started";
import { Next } from "./s08-next";

export const scenes: SceneMap = {
  "cold-open": ColdOpen,
  "the-idea": TheIdea,
  "two-shapes": TwoShapes,
  "at-a-glance": AtAGlance,
  diverged: Diverged,
  "four-verdicts": FourVerdicts,
  "getting-started": GettingStarted,
  next: Next,
};
