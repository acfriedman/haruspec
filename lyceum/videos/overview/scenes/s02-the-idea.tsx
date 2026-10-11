import React from "react";
import { useScene, Box, Fade, Line, Svg, Text, C, FONT, mix, prog, track } from "#kit";
import { ROLE, TestCard, TraceStrip, useAppear } from "./shared";

// The old code becomes the oracle: the same inputs drive both, and the two traces are compared row
// by row. Layout, top to bottom: the recalled test card (top-left corner) and a chip row (top
// centre) share y ≈ 190; box labels at 294; the two boxes from 326 to 776; the closing label at 862.

const BOX = { w: 600, h: 450, cy: 551, top: 326 };
const LEFT = 460;
const RIGHT = 1460;

/** Trace rows: size 30, so 45 px apart. The strips sit toward the gap so the connectors stay short. */
const ROW_SIZE = 30;
const ROW = ROW_SIZE * 1.5;
const STRIP_Y = 446;
const STRIP_W = 300;
const STRIP_X = { left: 400, right: 1212 };
const rowY = (i: number) => STRIP_Y + ROW / 2 + i * ROW;
const TRACE = ["call addItem", "post CartChanged", "call checkout", "return"];

const INPUTS: { text: string; seam?: boolean }[] = [{ text: "addCoffee" }, { text: "promo" }, { text: "checkout" }, { text: "coffeeQty = 7", seam: true }];

/** Blends two theme colours (`#RRGGBB`), `t` of the way from `a` to `b`. */
function blend(a: string, b: string, t: number): string {
  const ch = (c: string) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
  const A = ch(a);
  const B = ch(b);
  return "#" + A.map((v, i) => Math.round(mix(v, B[i], t)).toString(16).padStart(2, "0")).join("");
}

/** The generated inputs as a row of chips, centred on `x`/`y`. Chips are opaque so two copies can
 *  sit on top of each other at the moment the row splits. */
const InputRow: React.FC<{ x: number; y: number; scale: number; at: number }> = ({ x, y, scale, at }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) scale(${scale})`,
        display: "flex",
        gap: 14,
        whiteSpace: "nowrap",
      }}
    >
      {INPUTS.map((c, i) => {
        const p = prog(frame, at + Math.round(i * 0.12 * fps), 0.4, fps);
        const color = c.seam ? ROLE.seam : C.text;
        return (
          <span
            key={i}
            style={{
              fontFamily: FONT.mono,
              fontSize: 26,
              color,
              border: `2.5px solid ${c.seam ? ROLE.seam : C.dim}`,
              borderRadius: 999,
              padding: "4px 12px",
              background: C.surface,
              opacity: p,
              transform: `translateY(${(1 - p) * 10}px)`,
              display: "inline-block",
            }}
          >
            {c.text}
          </span>
        );
      })}
    </div>
  );
};

/** The things you don't write, as chips along the top: each writes on from `at` (staggered) and is
 *  struck through from its own frame in `strikes`. */
const NoRow: React.FC<{ y: number; words: string[]; at: number; strikes: number[] }> = ({ y, words, at, strikes }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  return (
    <div style={{ position: "absolute", left: 960, top: y, transform: "translate(-50%, -50%)", display: "flex", gap: 36, whiteSpace: "nowrap" }}>
      {words.map((w, i) => {
        const p = prog(frame, at + Math.round(i * 0.12 * fps), 0.4, fps);
        const s = prog(frame, strikes[i], 0.35, fps);
        return (
          <span
            key={i}
            style={{
              position: "relative",
              fontFamily: FONT.serif,
              fontSize: 36,
              color: blend(C.text, C.dim, s),
              border: `2.5px solid ${blend(C.dim, ROLE.diverged, s)}`,
              borderRadius: 999,
              padding: "2px 22px",
              background: C.surface,
              opacity: p,
              transform: `translateY(${(1 - p) * 10}px)`,
              display: "inline-block",
            }}
          >
            {w}
            <span
              style={{
                position: "absolute",
                left: 12,
                top: "50%",
                height: 4,
                marginTop: -2,
                width: `calc((100% - 24px) * ${s})`,
                borderRadius: 2,
                background: ROLE.diverged,
              }}
            />
          </span>
        );
      })}
    </div>
  );
};

/** A green "=" between two paired trace rows. */
const Equal: React.FC<{ y: number; at: number }> = ({ y, at }) => (
  <Fade x={960} y={y} anchor="center" at={at} dur={0.3}>
    <div
      style={{
        width: 36,
        height: 36,
        boxSizing: "border-box",
        borderRadius: 999,
        border: `2.5px solid ${ROLE.equivalent}`,
        background: C.bg,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: FONT.mono,
        fontSize: 28,
        fontWeight: 600,
        color: ROLE.equivalent,
      }}
    >
      =
    </div>
  </Fade>
);

/** One side's trace: four rows in step, the "post" row lit from `postAt`, and a late state row. */
const SideTrace: React.FC<{ x: number; color: string; at: number; postAt: number; stateAt: number }> = ({ x, color, at, postAt, stateAt }) => {
  const { frame, fps } = useScene();
  const g = frame >= postAt ? prog(frame, postAt, 0.5, fps) : 0;
  return (
    <>
      {g > 0 && (
        <div
          style={{
            position: "absolute",
            left: x + 4,
            top: STRIP_Y + ROW,
            width: STRIP_W + 16,
            height: ROW,
            borderRadius: 6,
            background: `${color}24`,
            boxShadow: `0 0 22px ${color}66`,
            opacity: g,
          }}
        />
      )}
      <TraceStrip x={x} y={STRIP_Y} w={STRIP_W} rows={TRACE} color={color} at={at} stagger={0.3} size={ROW_SIZE} marks={{ 1: blend(C.text, color, g) }} />
      <TraceStrip x={x} y={STRIP_Y + TRACE.length * ROW} w={STRIP_W} rows={["state snapshot"]} color={color} at={stateAt} size={ROW_SIZE} />
    </>
  );
};

export const TheIdea: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const start = cue("Haruspec's answer");
  const today = cue("does today");
  const correct = cue("correct means");
  const oracle = cue("oracle");
  const newOne = cue("the new one");
  const inputs = cue("the same generated inputs");
  const calls = cue("every call and return");
  const posts = cue("every notification");
  const state = cue("the state it leaves behind");
  const compare = cue("compares the two");
  const noMocks = cue("No mocks");
  const strikes = [cue("mocks"), cue("assertions"), cue("expected values")];
  const legacy = cue("legacy code is the expected value");
  const differential = cue("differential testing");
  const caveat = cue("best-effort oracle");
  const saysSo = cue("it says so");

  // The test card from scene 1 retreats to the corner, and grows a little when it gets its answer.
  const cardX = track(frame, fps, [[0, 1180], [start, 300]], 0.9);
  const cardY = track(frame, fps, [[0, 600], [start, 190]], 0.9);
  const cardS = track(frame, fps, [[0, 1], [start, 0.45], [legacy, 0.5]], 0.9);

  // One row of inputs, then two identical rows that drop into the boxes.
  const split = inputs + s(1.0);
  const rowY0 = track(frame, fps, [[0, 190], [split, BOX.top + 60]], 0.8);
  const rowS = track(frame, fps, [[0, 1], [split, 0.76]], 0.8);
  const leftRowX = track(frame, fps, [[0, 960], [split, LEFT]], 0.8);
  const rightRowX = track(frame, fps, [[0, 960], [split, RIGHT]], 0.8);

  // The legacy box lights up when it is named as the expected value.
  const lit = useAppear(legacy, differential + s(0.6), 0.6);

  // Everything recedes for the caveat.
  const recede = mix(1, 0.2, prog(frame, caveat, 0.7, fps));

  return (
    <>
      <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, opacity: recede }}>
        <TestCard x={cardX} y={cardY} scale={cardS} pulseAt={0} answerAt={legacy} answer="baseline" />

        {/* The two implementations. */}
        <Svg>
          <Box x={LEFT} y={BOX.cy} w={BOX.w} h={BOX.h} at={today} dur={0.8} color={ROLE.baseline} fill={`${ROLE.baseline}0A`} r={18} width={3} />
          <Box x={RIGHT} y={BOX.cy} w={BOX.w} h={BOX.h} at={newOne} dur={0.8} color={ROLE.candidate} fill={`${ROLE.candidate}0A`} r={18} width={3} />
        </Svg>
        {lit > 0 && (
          <div
            style={{
              position: "absolute",
              left: LEFT - BOX.w / 2,
              top: BOX.top,
              width: BOX.w,
              height: BOX.h,
              borderRadius: 18,
              boxShadow: `0 0 40px ${ROLE.baseline}AA`,
              opacity: lit,
            }}
          />
        )}
        <Text x={LEFT} y={BOX.top - 32} size={36} color={ROLE.baseline} at={today} dur={0.6}>
          baseline · legacy
        </Text>
        <Text x={RIGHT} y={BOX.top - 32} size={36} color={ROLE.candidate} at={newOne} dur={0.6}>
          candidate · port
        </Text>

        {/* What it does today is what correct means: the old code is the oracle. */}
        <Text x={LEFT} y={BOX.cy - 30} size={34} italic color={C.dim} at={today + s(0.4)} out={oracle} reveal="fade">
          today's behavior
        </Text>
        <Text x={LEFT} y={BOX.cy + 30} size={40} color={C.text} at={correct + s(0.2)} out={oracle}>
          = correct
        </Text>
        <Text x={LEFT} y={BOX.cy} size={60} color={ROLE.baseline} at={oracle} out={inputs} dur={0.7}>
          the oracle
        </Text>

        {/* The same generated inputs, into both. */}
        <InputRow x={leftRowX} y={rowY0} scale={rowS} at={inputs} />
        {frame >= split && <InputRow x={rightRowX} y={rowY0} scale={rowS} at={inputs} />}

        {/* What each does at its boundary. */}
        <SideTrace x={STRIP_X.left} color={ROLE.baseline} at={calls} postAt={posts} stateAt={state} />
        <SideTrace x={STRIP_X.right} color={ROLE.candidate} at={calls} postAt={posts} stateAt={state} />

        {/* Compared row by row. */}
        <Svg>
          {[0, 1, 2, 3, 4].map((i) => (
            <Line key={i} from={[LEFT + BOX.w / 2 + 12, rowY(i)]} to={[RIGHT - BOX.w / 2 - 12, rowY(i)]} at={compare + s(i * 0.12)} dur={0.45} color={C.dim} width={2.5} dashed />
          ))}
        </Svg>
        {[0, 1, 2, 3, 4].map((i) => (
          <Equal key={i} y={rowY(i)} at={compare + s(i * 0.12 + 0.25)} />
        ))}

        {/* What you don't write. */}
        <NoRow y={190} words={["mocks", "assertions", "expected values"]} at={noMocks} strikes={strikes} />

        <Text x={960} y={BOX.top + BOX.h + 86} size={60} color={C.text} at={differential} dur={0.9}>
          differential testing
        </Text>
      </div>

      {/* The caveat, from the project's front page. */}
      <Fade x={960} y={540} anchor="center" at={caveat} dur={0.5} scale={1}>
        <div style={{ width: 1100, height: 220, boxSizing: "border-box", borderRadius: 18, border: `2px solid ${C.faint}`, background: C.surface }} />
      </Fade>
      <Text x={960} y={500} size={48} color={C.text} at={caveat + s(0.3)} dur={0.9}>
        ⚠️ Haruspec is not omniscient.
      </Text>
      <Text x={960} y={580} size={48} color={C.text} at={caveat + s(1.1)} dur={0.8}>
        It is a best-effort oracle.
      </Text>
      <Text x={960} y={692} size={26} font="mono" color={C.dim} at={caveat + s(1.6)} reveal="fade">
        README.md
      </Text>
      <Svg>
        <Box x={960} y={540} w={1100} h={220} at={saysSo} dur={1.0} color={ROLE.cannotVerify} fill={`${C.surface}00`} r={18} width={4} />
      </Svg>
    </>
  );
};
