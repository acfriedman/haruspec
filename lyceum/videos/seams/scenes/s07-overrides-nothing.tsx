import React from "react";
import { useScene, Arrow, Fade, Svg, Text, C, FONT, lin, prog, track, visibility } from "#kit";
import { ROLE, Verdict, useAppear } from "./shared";

// Haruspec overrides nothing. Code that dispatches on its own (GCD, a bare Task, MainActor.run) is outside
// the seams: the source audit tags it `dispatch` (the dispatch channel, ChannelLint.swift), and a green
// with that finding reads CANNOT-VERIFY. Then every uncontrolled thing, side by side, with what it earns.

/** The three direct-dispatch chips, left column. */
const CHIP = { x: 140, w: 700, h: 72, size: 34 } as const;
const CHIP_Y = [470, 590, 710] as const;
const CHIP_CODE = ["DispatchQueue.main.async { … }", "Task { … }", "await MainActor.run { … }"] as const;

/** The amber `dispatch` tag: fixed width so the three can merge into one. */
const TAG_W = 176;
const TAG_X = CHIP.x + CHIP.w + 30 + TAG_W / 2;

/** The magnifier's column and the span it sweeps (its centre passes chip 3 on "dispatch"). */
const LENS = { x: 520, from: 380, to: CHIP_Y[2], r: 54 } as const;

/** The flip, on the right. */
const FLIP = { x: 1450, y: 590 } as const;

/** The summary rows: cause (right-aligned) → verdict pill (left edge fixed) → note. */
const ROW_Y = [410, 570, 730] as const;
const CAUSE_RIGHT = 620;
const PILL_LEFT = 790;
/** Estimated pill widths at size 40, so a note can sit just past its pill. */
const PILL_W = { unstable: 322, cannotVerify: 442 } as const;
const pillX = (kind: keyof typeof PILL_W) => PILL_LEFT + PILL_W[kind] / 2;
const noteX = (kind: keyof typeof PILL_W) => PILL_LEFT + PILL_W[kind] + 44;

const hex = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0");

/** A grey label — a verb and the API it would touch — that strikes through. `x`/`y` are its centre. */
const Struck: React.FC<{ x: number; y: number; verb: string; api: string; at: number; strikeAt: number; out: number }> = ({ x, y, verb, api, at, strikeAt, out }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.45);
  if (o <= 0) return null;
  const s = frame >= strikeAt ? prog(frame, strikeAt, 0.45, fps) : 0;
  return (
    <div style={{ position: "absolute", left: x, top: y, transform: `translate(-50%, -50%) translateY(${(1 - Math.min(1, o)) * 10}px)`, opacity: o, whiteSpace: "nowrap", color: C.dim }}>
      <span style={{ fontFamily: FONT.serif, fontSize: 32 }}>{verb} </span>
      <span style={{ fontFamily: FONT.mono, fontSize: 30 }}>{api}</span>
      <div style={{ position: "absolute", left: -10, top: "54%", height: 3, width: `calc(${s * 100}% + ${20 * s}px)`, background: C.dim, borderRadius: 2 }} />
    </div>
  );
};

/** A code chip that types on, and rings amber once the audit tags it. */
const CodeChip: React.FC<{ y: number; code: string; at: number; flagAt: number; out: number }> = ({ y, code, at, flagAt, out }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  const n = Math.ceil(lin(frame, at + Math.round(0.1 * fps), 0.8, fps) * code.length);
  const flag = frame >= flagAt ? prog(frame, flagAt, 0.35, fps) : 0;
  return (
    <div
      style={{
        position: "absolute",
        left: CHIP.x,
        top: y - CHIP.h / 2,
        width: CHIP.w,
        height: CHIP.h,
        boxSizing: "border-box",
        borderRadius: 12,
        border: `2.5px solid ${C.faint}`,
        background: C.surface,
        display: "flex",
        alignItems: "center",
        padding: "0 26px",
        fontFamily: FONT.mono,
        fontSize: CHIP.size,
        color: C.text,
        whiteSpace: "pre",
        opacity: o,
      }}
    >
      <span>{code.slice(0, n)}</span>
      <span style={{ opacity: 0 }}>{code.slice(n)}</span>
      <div style={{ position: "absolute", inset: -2.5, borderRadius: 12, border: `2.5px solid ${ROLE.cannotVerify}`, opacity: flag }} />
    </div>
  );
};

/** The amber `dispatch` finding tag. `x`/`y` are its centre. */
const Tag: React.FC<{ x: number; y: number; opacity: number; ring?: number; pulse?: number }> = ({ x, y, opacity, ring = 0, pulse = 0 }) =>
  opacity <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translate(-50%, -50%)",
        width: TAG_W,
        boxSizing: "border-box",
        textAlign: "center",
        fontFamily: FONT.mono,
        fontSize: 28,
        fontWeight: 600,
        color: ROLE.cannotVerify,
        border: `2.5px solid ${ROLE.cannotVerify}`,
        background: C.surface,
        borderRadius: 999,
        padding: "4px 0",
        opacity,
        boxShadow: seamRing(ring, pulse),
      }}
    >
      dispatch
    </div>
  );

/** The teal ring a cause takes on "which one": it is a seam to inject. */
const seamRing = (ring: number, pulse: number) =>
  ring > 0 ? `0 0 0 ${3.5 * ring}px ${ROLE.seam}${hex(ring)}, 0 0 ${22 * pulse}px ${ROLE.seam}` : "none";

/** A code term in a summary row's cause column. */
const Term: React.FC<{ children: string; ring: number; pulse: number }> = ({ children, ring, pulse }) => (
  <span
    style={{
      fontFamily: FONT.mono,
      fontSize: 32,
      color: C.text,
      border: `2.5px solid ${C.faint}`,
      background: C.surface,
      borderRadius: 10,
      padding: "4px 16px",
      boxShadow: seamRing(ring, pulse),
      whiteSpace: "nowrap",
    }}
  >
    {children}
  </span>
);

/** The magnifying glass: a ring and a handle, centred at `y`. */
const Lens: React.FC<{ y: number; opacity: number }> = ({ y, opacity }) =>
  opacity <= 0 ? null : (
    <g opacity={opacity} transform={`translate(${LENS.x}, ${y})`}>
      <circle r={LENS.r} fill={`${C.dim}1A`} stroke={C.dim} strokeWidth={6} />
      <line x1={LENS.r * 0.72} y1={LENS.r * 0.72} x2={LENS.r * 1.62} y2={LENS.r * 1.62} stroke={C.dim} strokeWidth={13} strokeLinecap="round" />
    </g>
  );

/** Scales its content vertically about (x, y): a card flipping over. */
const FlipY: React.FC<{ x: number; y: number; s: number; children: React.ReactNode }> = ({ x, y, s, children }) =>
  s <= 0 ? null : (
    <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, transformOrigin: `${x}px ${y}px`, transform: `scaleY(${s})` }}>{children}</div>
  );

/** `blind spots: dispatch`, as the report spells it. `x` is its left edge. */
const BlindSpots: React.FC<{ x: number; y: number; at: number; out?: number }> = ({ x, y, at, out }) => (
  <Fade x={x} y={y} anchor="left" at={at} out={out} rise={8}>
    <div style={{ fontFamily: FONT.mono, fontSize: 28, color: C.text, whiteSpace: "nowrap" }}>
      blind spots: <span style={{ color: ROLE.cannotVerify }}>dispatch</span>
    </div>
  </Fade>
);

export const OverridesNothing: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const overrides = cue("overrides nothing");
  const redefine = cue("redefine");
  const gcdEnd = cue("Grand Central Dispatch", { end: true });
  const patch = cue("patch your tasks");
  const tasksEnd = cue("patch your tasks", { end: true });
  const direct = cue("dispatches directly");
  const bare = cue("spawns a bare task");
  const mainRun = cue("calls main actor run");
  const outside = cue("outside the seams");
  const audit = cue("The audit reads your source");
  const named = cue("dispatch", { after: audit });
  const green = cue("green");
  const becomes = cue("becomes", { after: green });
  const flip = cue("cannot verify", { after: green });
  const settle = cue("The same honesty");
  const makesUp = cue("makes up");
  const readsUnstable = cue("reads unstable");
  const unstable = cue("unstable", { after: makesUp });
  const field = cue("names the field");
  const pastRead = cue("A read past the recording");
  const readsCannot = cue("reads cannot verify");
  const cannot2 = cue("cannot verify", { after: pastRead });
  const never = cue("never silently mocks");
  const whichOne = cue("which one");
  const inject = cue("what to inject");

  // The magnifier sweeps down at constant speed, reaching chip 3 as the narration says "dispatch".
  const sweep = Math.max(1, named - audit);
  const lensY = LENS.from + ((LENS.to - LENS.from) * (frame - audit)) / sweep;
  const lensO = frame < audit ? 0 : prog(frame, audit, 0.3, fps) * visibility(frame, fps, undefined, named + s(0.35), 0.4);
  const tagAt = CHIP_Y.map((y) => audit + Math.round(((y - LENS.from) / (LENS.to - LENS.from)) * sweep));

  // As the rows take over, the chips clear, the three tags merge into row 3's cause, and only then
  // does the pill drop into row 3 (so it never crosses the tags).
  const merge = settle + s(0.35);
  const drop = settle + s(0.75);
  const row3 = settle + s(1.6);
  const tagHome = CAUSE_RIGHT - TAG_W / 2;
  const tagX = track(frame, fps, [[0, TAG_X], [merge, tagHome]], 0.8);
  const ring = frame >= whichOne ? prog(frame, whichOne, 0.4, fps) : 0;
  const pulse = frame >= whichOne ? ring * (0.5 + 0.5 * Math.sin(((frame - whichOne) / fps) * Math.PI * 2 * 0.8)) : 0;

  const eqS = frame < flip ? 1 : 1 - prog(frame, flip, 0.22, fps);
  const cvS = frame < flip + s(0.2) ? 0 : prog(frame, flip + s(0.2), 0.25, fps);
  const pillPos = {
    x: track(frame, fps, [[0, FLIP.x], [drop, pillX("cannotVerify")]], 0.9),
    y: track(frame, fps, [[0, FLIP.y], [drop, ROW_Y[2]]], 0.9),
  };

  return (
    <>
      {/* The header, and what Haruspec refuses to touch. */}
      <Text x={960} y={170} size={52} font="serif" at={overrides} dur={0.9} out={never}>
        Haruspec overrides nothing
      </Text>
      <Struck x={740} y={258} verb="redefine" api="dispatch_async" at={redefine} strikeAt={gcdEnd} out={settle} />
      <Struck x={1240} y={258} verb="patch" api="Task" at={patch} strikeAt={tasksEnd} out={settle} />

      {/* Code that dispatches on its own: outside the seams. */}
      <Text x={CHIP.x} y={390} size={30} italic color={C.dim} anchor="left" at={outside} reveal="fade" out={settle}>
        outside the seams
      </Text>
      {CHIP_CODE.map((code, i) => (
        <CodeChip key={i} y={CHIP_Y[i]} code={code} at={[direct, bare, mainRun][i]} flagAt={tagAt[i]} out={settle} />
      ))}

      {/* The audit's tags: each attaches as the lens passes, then all three merge into row 3. */}
      {CHIP_Y.map((y, i) => {
        const a = frame >= tagAt[i] ? prog(frame, tagAt[i], 0.35, fps) : 0;
        const ty = track(frame, fps, [[0, y], [merge, ROW_Y[2]]], 0.8);
        const keep = i === 1 ? 1 : visibility(frame, fps, undefined, merge + s(0.8), 0.3);
        return <Tag key={i} x={tagX - (1 - a) * 28} y={ty} opacity={a * keep} ring={i === 1 ? ring : 0} pulse={i === 1 ? pulse : 0} />;
      })}

      <Svg>
        <Lens y={lensY} opacity={lensO} />
        {/* The finding feeds the verdict. */}
        <Arrow from={[TAG_X + TAG_W / 2 + 18, FLIP.y]} to={[1200, FLIP.y]} at={becomes} out={settle} dur={0.4} color={C.dim} />
        {/* Summary-row arrows: cause → verdict. */}
        <Arrow from={[CAUSE_RIGHT + 24, ROW_Y[0]]} to={[PILL_LEFT - 24, ROW_Y[0]]} at={readsUnstable} dur={0.35} color={C.dim} />
        <Arrow from={[CAUSE_RIGHT + 24, ROW_Y[1]]} to={[PILL_LEFT - 24, ROW_Y[1]]} at={readsCannot} dur={0.35} color={C.dim} />
        <Arrow from={[CAUSE_RIGHT + 24, ROW_Y[2]]} to={[PILL_LEFT - 24, ROW_Y[2]]} at={row3} dur={0.35} color={C.dim} />
      </Svg>

      {/* A green with that finding flips to CANNOT-VERIFY, then drops into row 3. */}
      <FlipY x={FLIP.x} y={FLIP.y} s={eqS}>
        <Verdict x={FLIP.x} y={FLIP.y} kind="equivalent" at={green} />
      </FlipY>
      <FlipY x={pillPos.x} y={pillPos.y} s={cvS}>
        <Verdict x={pillPos.x} y={pillPos.y} kind="cannotVerify" />
      </FlipY>
      <BlindSpots x={FLIP.x - 176} y={FLIP.y + 84} at={flip + s(0.5)} out={settle} />
      <BlindSpots x={noteX("cannotVerify")} y={ROW_Y[2]} at={row3} />

      {/* Row 1: a value the subject makes up. */}
      <Fade x={CAUSE_RIGHT} y={ROW_Y[0]} anchor="right" at={makesUp} rise={10}>
        <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
          <Term ring={ring} pulse={pulse}>UUID()</Term>
          <span style={{ fontFamily: FONT.mono, fontSize: 32, color: C.dim }}>·</span>
          <Term ring={ring} pulse={pulse}>Date()</Term>
        </div>
      </Fade>
      <Verdict x={pillX("unstable")} y={ROW_Y[0]} kind="unstable" at={unstable} />
      <Text x={noteX("unstable")} y={ROW_Y[0]} size={32} italic color={C.dim} anchor="left" at={field} dur={0.6}>
        names the field
      </Text>

      {/* Row 2: a read past the recording. */}
      <Fade x={CAUSE_RIGHT} y={ROW_Y[1]} anchor="right" at={pastRead} rise={10}>
        <Term ring={ring} pulse={pulse}>unrecorded reach</Term>
      </Fade>
      <Verdict x={pillX("cannotVerify")} y={ROW_Y[1]} kind="cannotVerify" at={cannot2} />
      <Text x={noteX("cannotVerify")} y={ROW_Y[1]} size={32} italic color={C.dim} anchor="left" at={cannot2 + s(0.5)} dur={0.6}>
        names the seam
      </Text>

      {/* The close: nothing is mocked behind your back; each cause is a seam to inject. */}
      <Text x={960} y={170} size={52} font="serif" at={never + s(0.3)} dur={0.9}>
        never silently mocked
      </Text>
      <Text x={960} y={880} size={34} italic color={ROLE.seam} at={inject} dur={0.8}>
        inject it through the initializer
      </Text>
    </>
  );
};
