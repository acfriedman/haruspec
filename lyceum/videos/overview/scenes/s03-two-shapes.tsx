import React from "react";
import { useScene, Arrow, Box, Fade, Line, Svg, Text, C, FONT, along, mix, prog, track, visibility } from "#kit";
import { ROLE, useAppear } from "./shared";

// The two shapes, side by side. Left, a campaign: the legacy class and its port live in one build and
// are compared live until the old code is deleted. Right, continuous: main's behaviour is recorded once
// as a plan and your branch replays it; on merge the branch becomes the next baseline. One spec drives
// both. The bottom strip quotes the README's table.

type P = [number, number];

const RULE_X = 960;
const TITLE_Y = 150;

// Campaign (left panel, centred on x 520).
const BUILD = { x: 520, y: 400, w: 790, h: 320 }; // x 125–915, y 240–560
const CLASS = { w: 300, h: 110, y: 405 };
const LEGACY_X = 315;
const PORT_X = 725;
const LIVE_L = LEGACY_X + CLASS.w / 2 + 12;
const LIVE_R = PORT_X - CLASS.w / 2 - 12;
const EXAMPLE_Y = 615;
const CHECK: P = [735, CLASS.y];

// Continuous (right panel, centred on x 1400).
const STACK_X = 1260;
const MAIN_Y = 330;
const BRANCH_Y = 580;
const BUILD_R = { w: 400, h: 130 };
const CHIP = { x: 1650, y: MAIN_Y, w: 130, h: 110 };
const REPLAY_FROM: P = [CHIP.x, CHIP.y + CHIP.h / 2 + 10];
const REPLAY_TO: P = [STACK_X + BUILD_R.w / 2 + 14, BRANCH_Y];
const REPLAY_BEND = -40;

// The spec, beneath both.
const SPEC = { x: 960, y: 810, w: 400, h: 88 };
const STRIP_Y = 950;

/** A short glow that rises at `at` and dies away. */
function bump(frame: number, fps: number, at: number): number {
  if (frame < at) return 0;
  return prog(frame, at, 0.3, fps) * (1 - prog(frame, at + Math.round(0.5 * fps), 0.9, fps));
}

/** A panel title, dim from `at`, lit to full text colour from `lit`. `x`/`y` are its centre. */
const PanelTitle: React.FC<{ x: number; y: number; text: string; at: number; lit: number }> = ({ x, y, text, at, lit }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at);
  if (o <= 0) return null;
  const l = frame < lit ? 0 : prog(frame, lit, 0.5, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) scale(${mix(1, 1.04, l)})`,
        opacity: o,
        fontFamily: FONT.serif,
        fontSize: 54,
        lineHeight: "64px",
        whiteSpace: "nowrap",
      }}
    >
      <span style={{ color: C.dim, opacity: 1 - l }}>{text}</span>
      <span style={{ position: "absolute", left: 0, top: 0, color: C.text, opacity: l }}>{text}</span>
    </div>
  );
};

/** A rounded box with a label, centred or as a header. Opaque unless `wash` is off, so things drawn
 *  before it hide beneath it. `x`/`y` are its centre. */
const Block: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  color: string;
  label: string;
  at: number;
  out?: number;
  labelColor?: string;
  size?: number;
  italic?: boolean;
  /** Pixels from the top for a header label; omit to centre it. */
  labelTop?: number;
  radius?: number;
  glow?: number;
  wash?: boolean;
}> = ({ x, y, w, h, color, label, at, out, labelColor = color, size = 30, italic = false, labelTop, radius = 14, glow = 0, wash = true }) => {
  const o = useAppear(at, out);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        boxSizing: "border-box",
        borderRadius: radius,
        border: `3px solid ${color}`,
        background: wash ? `linear-gradient(180deg, ${color}24, ${color}0A), ${C.surface}` : `${C.text}06`,
        opacity: o,
        transform: `scale(${mix(0.94, 1, o)})`,
        boxShadow: glow > 0 ? `0 0 ${36 * glow}px ${color}` : "none",
        display: "flex",
        justifyContent: "center",
        alignItems: labelTop === undefined ? "center" : "flex-start",
        paddingTop: labelTop ?? 0,
        fontFamily: FONT.serif,
        fontStyle: italic ? "italic" : "normal",
        fontSize: size,
        color: labelColor,
        whiteSpace: "nowrap",
      }}
    >
      {label}
    </div>
  );
};

/** A small rounded tag in a role colour. `x`/`y` are its centre. */
const Tag: React.FC<{ x: number; y: number; text: string; color: string; at: number; out?: number }> = ({ x, y, text, color, at, out }) => (
  <Fade x={x} y={y} anchor="center" at={at} out={out} rise={8}>
    <div
      style={{
        fontFamily: FONT.serif,
        fontStyle: "italic",
        fontSize: 26,
        color,
        border: `2.5px solid ${color}`,
        borderRadius: 999,
        padding: "2px 18px",
        background: `${color}18`,
        whiteSpace: "nowrap",
      }}
    >
      {text}
    </div>
  </Fade>
);

/** The second campaign example, "serial queue → actor": the old half at `at`, the new half at `then`. */
const Example: React.FC<{ x: number; y: number; at: number; then: number }> = ({ x, y, at, then }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const a = prog(frame, at, 0.5, fps);
  const b = frame < then ? 0 : prog(frame, then, 0.5, fps);
  const part = (p: number): React.CSSProperties => ({ opacity: p, display: "inline-block", transform: `translateX(${(1 - p) * -12}px)` });
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translate(-50%, -50%)",
        fontFamily: FONT.serif,
        fontStyle: "italic",
        fontSize: 30,
        whiteSpace: "nowrap",
        display: "flex",
        gap: 14,
      }}
    >
      <span style={{ ...part(a), color: ROLE.baseline }}>serial queue</span>
      <span style={{ ...part(b), color: C.dim }}>→</span>
      <span style={{ ...part(b), color: ROLE.candidate }}>actor</span>
    </div>
  );
};

/** The recorded plan: a document chip with a folded corner. From `flipAt` it turns over to show a
 *  refresh glyph. `x`/`y` are its centre. */
const PlanChip: React.FC<{ x: number; y: number; at: number; flipAt: number; glow?: number }> = ({ x, y, at, flipAt, glow = 0 }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.35);
  if (o <= 0) return null;
  const p = frame < flipAt ? 0 : prog(frame, flipAt, 0.7, fps);
  const sx = Math.max(0.03, Math.abs(Math.cos(Math.PI * p)));
  const back = p >= 0.5;
  const { w, h } = CHIP;
  const fold = 26;
  const outline = `M2,2 H${w - fold} L${w - 2},${fold} V${h - 2} H2 Z`;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        opacity: o,
        transform: `scaleX(${sx})`,
        filter: glow > 0 ? `drop-shadow(0 0 ${18 * glow}px ${ROLE.plan})` : undefined,
      }}
    >
      <svg width={w} height={h} style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        <path d={outline} fill={C.surface} />
        <path d={outline} fill={`${ROLE.plan}1C`} stroke={ROLE.plan} strokeWidth={3} strokeLinejoin="round" />
        <path d={`M${w - fold},2 V${fold} H${w - 2}`} fill="none" stroke={ROLE.plan} strokeWidth={2.5} strokeLinejoin="round" />
      </svg>
      <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 8 }}>
        {back ? (
          <div style={{ fontFamily: FONT.mono, fontSize: 52, lineHeight: "52px", color: ROLE.plan }}>↻</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 9, alignItems: "flex-start", width: w * 0.56, paddingTop: 6 }}>
            {[1, 0.7].map((f, i) => (
              <div key={i} style={{ height: 6, width: `${f * 100}%`, borderRadius: 3, background: `${ROLE.plan}77` }} />
            ))}
          </div>
        )}
        <div style={{ fontFamily: FONT.serif, fontSize: 30, lineHeight: "34px", color: ROLE.plan }}>plan</div>
      </div>
    </div>
  );
};

/** A check in a ring that draws on (SVG; render inside `Svg`). */
const CheckMark: React.FC<{ at: P; from: number; color: string }> = ({ at: [x, y], from, color }) => {
  const { frame, fps } = useScene();
  if (frame < from) return null;
  const ring = prog(frame, from, 0.5, fps);
  const tick = prog(frame, from + Math.round(0.25 * fps), 0.45, fps);
  return (
    <g fill="none" stroke={color} strokeLinecap="round" strokeLinejoin="round">
      <circle cx={x} cy={y} r={32} strokeWidth={3} pathLength={1} strokeDasharray={1} strokeDashoffset={1 - ring} fill={`${color}1A`} />
      <path d={`M${x - 14},${y + 1} L${x - 4},${y + 12} L${x + 15},${y - 11}`} strokeWidth={5} pathLength={1} strokeDasharray={1} strokeDashoffset={1 - tick} />
    </g>
  );
};

export const TwoShapes: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const shapes = cue("two shapes");
  const campaign = cue("a campaign");
  const objc = cue("Objective-C");
  const swift = cue("Swift");
  const serial = cue("serial queue");
  const actor = cue("an actor");
  const liveSame = cue("live in the same build");
  const sameBuild = cue("same build");
  const runsLive = cue("runs live");
  const asBaseline = cue("the baseline");
  const checked = cue("checked against it");
  const ships = cue("the port ships");
  const deleted = cue("the old code is deleted");

  const continuous = cue("continuous", { after: campaign });
  const oneImpl = cue("one implementation");
  const main = cue("main", { after: continuous });
  const branch = cue("your branch", { after: main });
  const recorded = cue("recorded once, as a plan");
  const replays = cue("your branch replays it");
  const merges = cue("merges");
  const becomes = cue("becomes");
  const nextBaseline = cue("next baseline");

  const same = cue("The same spec drives both");
  const drives = cue("drives both");

  // The campaign steps back while the continuous shape is told, and returns for the shared spec.
  const leftOpacity = track(frame, fps, [[0, 1], [continuous, 0.4], [same, 1]], 0.6);

  // Campaign: once the old code is deleted, the port slides to the centre of the build.
  const portX = track(frame, fps, [[0, PORT_X], [deleted + s(0.3), BUILD.x]], 0.8);

  // Live checking: a pink pulse runs port → legacy, then a blue one back, until the old code goes.
  const liveFlow = visibility(frame, fps, checked, deleted, 0.3);
  const livePhase = frame < checked ? 0 : (((frame - checked) / fps) / 1.2) % 1;
  const liveBack = livePhase >= 0.5;
  const liveT = (livePhase % 0.5) * 2;
  const liveDotX = liveBack ? mix(LIVE_L + 6, LIVE_R - 6, liveT) : mix(LIVE_R - 6, LIVE_L + 6, liveT);

  // Continuous: the plan slides out of main; on merge the branch takes main's place.
  const chipX = track(frame, fps, [[0, STACK_X], [recorded, CHIP.x]], 0.9);
  const branchY = track(frame, fps, [[0, BRANCH_Y], [merges, MAIN_Y]], 0.9);

  // Replay: a plan-yellow pulse runs from the plan into the branch until it merges.
  const replayStart = replays + s(0.6);
  const replayFlow = visibility(frame, fps, replayStart, merges, 0.3);
  const replayT = frame < replayStart ? 0 : (((frame - replayStart) / fps) / 1.3) % 1;
  const replayDot = along(REPLAY_FROM, REPLAY_TO, REPLAY_BEND, replayT);

  return (
    <>
      <Svg>
        <Line from={[RULE_X, 122]} to={[RULE_X, 715]} at={0} dur={0.9} color={C.faint} width={2} />
      </Svg>
      <PanelTitle x={BUILD.x} y={TITLE_Y} text="Campaign" at={shapes} lit={campaign} />
      <PanelTitle x={1400} y={TITLE_Y} text="Continuous" at={shapes} lit={continuous} />

      {/* Campaign: two implementations, one build. */}
      <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, opacity: leftOpacity }}>
        <Block
          x={BUILD.x}
          y={BUILD.y}
          w={BUILD.w}
          h={BUILD.h}
          color={C.dim}
          label="one build"
          labelColor={C.dim}
          italic
          labelTop={20}
          radius={26}
          wash={false}
          at={campaign}
          glow={bump(frame, fps, sameBuild) * 0.6}
        />
        <Block
          x={LEGACY_X}
          y={CLASS.y}
          w={CLASS.w}
          h={CLASS.h}
          color={ROLE.baseline}
          label="Legacy · Objective-C"
          size={28}
          at={campaign + s(0.3)}
          out={deleted}
          glow={Math.min(1, bump(frame, fps, objc) + bump(frame, fps, runsLive))}
        />
        <Block
          x={portX}
          y={CLASS.y}
          w={CLASS.w}
          h={CLASS.h}
          color={ROLE.candidate}
          label="Port · Swift"
          size={28}
          at={campaign + s(0.55)}
          glow={Math.min(1, bump(frame, fps, swift) + bump(frame, fps, ships) + bump(frame, fps, deleted + s(0.9)))}
        />
        <Svg>
          <Arrow from={[LIVE_L, CLASS.y]} to={[LIVE_R, CLASS.y]} at={liveSame} dur={0.5} color={C.text} width={3} out={deleted} />
          <Arrow from={[LIVE_R, CLASS.y]} to={[LIVE_L, CLASS.y]} at={liveSame} dur={0.5} color={C.text} width={3} out={deleted} />
          {liveFlow > 0 && <circle cx={liveDotX} cy={CLASS.y} r={7} fill={liveBack ? ROLE.baseline : ROLE.candidate} opacity={liveFlow} />}
          <CheckMark at={CHECK} from={deleted + s(0.9)} color={ROLE.equivalent} />
        </Svg>
        <Text x={BUILD.x} y={CLASS.y - 40} size={28} italic color={C.text} at={liveSame} out={deleted} reveal="fade" dur={0.4}>
          live
        </Text>
        <Tag x={LEGACY_X} y={507} text="baseline" color={ROLE.baseline} at={asBaseline} out={deleted} />

        <Example x={BUILD.x} y={EXAMPLE_Y} at={serial} then={actor} />

        <Text x={BUILD.x} y={STRIP_Y} size={26} color={C.dim} at={sameBuild} dur={0.8}>
          Compares: two implementations, one build
        </Text>
      </div>

      {/* Continuous: one implementation, two builds. The plan is drawn first so it emerges from under main. */}
      <PlanChip x={chipX} y={CHIP.y} at={recorded} flipAt={becomes} glow={bump(frame, fps, becomes + s(0.4))} />
      <Block
        x={STACK_X}
        y={MAIN_Y}
        w={BUILD_R.w}
        h={BUILD_R.h}
        color={ROLE.baseline}
        label="main"
        size={38}
        radius={24}
        at={continuous + s(0.2)}
        out={merges}
        glow={Math.min(1, bump(frame, fps, main) + bump(frame, fps, recorded))}
      />
      <Svg>
        <Arrow from={REPLAY_FROM} to={REPLAY_TO} bend={REPLAY_BEND} at={replays} dur={0.6} color={ROLE.plan} width={4} out={merges} />
        {replayFlow > 0 && <circle cx={replayDot[0]} cy={replayDot[1]} r={7} fill={ROLE.plan} opacity={replayFlow} />}
      </Svg>
      <Block
        x={STACK_X}
        y={branchY}
        w={BUILD_R.w}
        h={BUILD_R.h}
        color={ROLE.candidate}
        label="your branch"
        size={38}
        radius={24}
        at={continuous + s(0.45)}
        glow={Math.min(1, bump(frame, fps, branch) + bump(frame, fps, replays + s(0.5)) + bump(frame, fps, merges + s(0.6)))}
      />
      <Text x={CHIP.x} y={CHIP.y + CHIP.h / 2 + 44} size={28} italic color={C.text} at={nextBaseline} reveal="fade" dur={0.5}>
        next baseline
      </Text>
      <Text x={1400} y={STRIP_Y} size={26} color={C.dim} at={oneImpl} dur={0.8}>
        Compares: one implementation, two builds
      </Text>

      {/* One spec drives both. */}
      <Svg>
        <Box x={SPEC.x} y={SPEC.y} w={SPEC.w} h={SPEC.h} at={same} dur={0.6} color={C.text} fill={C.surface} r={16} width={3} />
        <Arrow from={[SPEC.x - 90, SPEC.y - SPEC.h / 2 - 6]} to={[720, BUILD.y + BUILD.h / 2 + 12]} at={drives} dur={0.6} color={C.text} width={3} opacity={0.8} />
        <Arrow from={[SPEC.x + 90, SPEC.y - SPEC.h / 2 - 6]} to={[STACK_X, MAIN_Y + BUILD_R.h / 2 + 14]} at={drives} dur={0.6} color={C.text} width={3} opacity={0.8} />
      </Svg>
      <Text x={SPEC.x} y={SPEC.y} size={34} font="mono" color={C.text} at={same + s(0.25)} dur={0.7}>
        {"Spec<PromoCart>"}
      </Text>
    </>
  );
};
