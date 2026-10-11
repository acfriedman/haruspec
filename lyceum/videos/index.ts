// The registry: one entry per video directory. `lyceum scenes <video>` adds a video's narration
// and scene map here.

import type { Narration, SceneMap } from "#kit";
import overviewNarration from "./overview/narration.json";
import { scenes as overviewScenes } from "./overview/scenes";
import specsNarration from "./specs/narration.json";
import { scenes as specsScenes } from "./specs/scenes";
import seamsNarration from "./seams/narration.json";
import { scenes as seamsScenes } from "./seams/scenes";
import verdictsNarration from "./verdicts/narration.json";
import { scenes as verdictsScenes } from "./verdicts/scenes";

export const videos: { narration: Narration; scenes: SceneMap }[] = [
  { narration: overviewNarration as Narration, scenes: overviewScenes },
  { narration: specsNarration as Narration, scenes: specsScenes },
  { narration: seamsNarration as Narration, scenes: seamsScenes },
  { narration: verdictsNarration as Narration, scenes: verdictsScenes },
];
