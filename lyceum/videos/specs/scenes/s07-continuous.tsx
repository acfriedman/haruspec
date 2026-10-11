import React from "react";
import { useScene, Arrow, Box, Fade, Svg, Text, C, FONT, mix, prog, track, visibility } from "#kit";
import { CodeCard, ROLE, VERDICT, useAppear } from "./shared";

// The @Continuous card is the README's snippet (its spec body elided, as the README does). The closing
// spec is scene 1's CartMigrationSpec.swift block, unchanged. The shapes table follows the README's two
// columns: campaign (two implementations, one build) and continuous (one implementation, two builds).

const CONTINUOUS = [
  "@Continuous(baseline: CartManager.self)",
  "struct CartMigrationSpec: SpecProviding {",
  "    var spec: Spec<Cart> { … }",
  "}",
];

const SPEC = [
  "Spec<Cart> {",
  '    Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))',
  '    Amend("removeSku").varying("sku", over: .oneOf(Catalog.skus))',
  '    Amend("checkout").last()',
  "}",
];

/** Two hex digits of alpha for `a` (0…1), to append to a `C` colour. */
const alpha = (a: number) => Math.round(Math.max(0, Math.min(1, a)) * 255).toString(16).padStart(2, "0");

// The @Continuous card on the left, and where `CartManager.self` sits on its first line (CodeCard's
// layout: 3 px border, 52 px header, 18 px / 24 px body padding).
const CARD = { x: 490, y: 540, w: 820, size: 28 };
const CARD_TOP = CARD.y - (52 + CONTINUOUS.length * CARD.size * 1.55 + 36) / 2;
const COL = CARD.size * 0.6;
const CODE_LEFT = CARD.x - CARD.w / 2 + 3 + 24;
const WATCH = {
  x: CODE_LEFT + COL * (22 + 38) / 2,
  y: CARD_TOP + 3 + 53 + 18 + (CARD.size * 1.55) / 2,
  w: COL * 16 + 14,
  h: CARD.size * 1.55 + 4,
};

// The record-and-replay flow, below the table on the right.
const MAIN = { x: 1110, y: 790, w: 220, h: 96 };
const BRANCH = { x: 1690, y: 790, w: 280, h: 96 };
const CHIP_Y = 700;
const VERBS_Y = 888;

// The shapes table.
const COL_W = 430;
const GAP = 20;
const TABLE_W = COL_W * 2 + GAP;
const COL_H = 200;
const TABLE_H = COL_H + 98;

type Column = { title: string; rows: string[]; lit: number[]; emphasis: number };

/** The README's two shapes, side by side; each cell brightens with its `lit` (0…1). The shared
 *  `Spec<Cart>` hangs beneath both columns from `spec` (0…1). `x`/`y` are its centre. */
const ShapesTable: React.FC<{ x: number; y: number; opacity: number; cols: Column[]; spec: number }> = ({ x, y, opacity, cols, spec }) => {
  if (opacity <= 0) return null;
  return (
    <div style={{ position: "absolute", left: x - TABLE_W / 2, top: y - TABLE_H / 2, width: TABLE_W, height: TABLE_H, opacity }}>
      {cols.map((c, i) => (
        <div
          key={i}
          style={{
            position: "absolute",
            left: i * (COL_W + GAP),
            top: 0,
            width: COL_W,
            height: COL_H,
            boxSizing: "border-box",
            borderRadius: 16,
            border: `2.5px solid ${C.text}${alpha(mix(0.2, 0.85, c.emphasis))}`,
            background: `${C.text}${alpha(0.07 * c.emphasis)}`,
            boxShadow: c.emphasis > 0.6 ? `0 0 ${24 * (c.emphasis - 0.6)}px ${C.text}55` : "none",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            paddingTop: 20,
          }}
        >
          <div style={{ fontFamily: FONT.serif, fontSize: 44, lineHeight: "56px", color: C.text, opacity: mix(0.3, 1, c.lit[0]) }}>{c.title}</div>
          <div style={{ width: COL_W - 80, height: 2, margin: "10px 0 8px", background: `${C.text}${alpha(mix(0.15, 0.45, c.emphasis))}` }} />
          {c.rows.map((r, j) => (
            <div key={j} style={{ fontFamily: FONT.serif, fontSize: 30, lineHeight: "46px", color: C.text, opacity: mix(0.3, 1, c.lit[j + 1]) }}>
              {r}
            </div>
          ))}
        </div>
      ))}
      {spec > 0 && (
        <div style={{ opacity: spec }}>
          <div
            style={{
              position: "absolute",
              left: COL_W / 2,
              top: COL_H + 10,
              width: COL_W + GAP,
              height: 22 * spec,
              boxSizing: "border-box",
              border: `2px solid ${C.dim}`,
              borderTop: "none",
              borderRadius: "0 0 10px 10px",
            }}
          />
          <div style={{ position: "absolute", left: TABLE_W / 2 - 1, top: COL_H + 32, width: 2, height: 14, background: C.dim }} />
          <div
            style={{
              position: "absolute",
              left: TABLE_W / 2,
              top: COL_H + 46,
              transform: `translate(-50%, 0) translateY(${(1 - spec) * 10}px)`,
              fontFamily: FONT.mono,
              fontSize: 28,
              color: C.text,
              border: `2.5px solid ${C.text}`,
              borderRadius: 999,
              padding: "3px 22px",
              background: C.surface,
              whiteSpace: "nowrap",
            }}
          >
            Spec&lt;Cart&gt;
          </div>
        </div>
      )}
    </div>
  );
};

/** A build in the flow: a rounded box with a label. `stack` (0…1) fans two more copies out behind it;
 *  `glow` (0…1) rings it in the plan's colour. `x`/`y` are its centre. */
const Build: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  label: string;
  color: string;
  mono?: boolean;
  at: number;
  out: number;
  stack?: number;
  glow?: number;
}> = ({ x, y, w, h, label, color, mono, at, out, stack = 0, glow = 0 }) => {
  const o = useAppear(at, out, 0.5);
  if (o <= 0) return null;
  const panel = (dx: number, dy: number, shrink: number, op: number, key: string, children?: React.ReactNode) => (
    <div
      key={key}
      style={{
        position: "absolute",
        left: x - (w - shrink) / 2 + dx,
        top: y - h / 2 + dy,
        width: w - shrink,
        height: h,
        boxSizing: "border-box",
        borderRadius: 14,
        border: `3px solid ${color}${alpha(op)}`,
        background: `linear-gradient(${color}1A, ${color}1A), ${C.bg}`,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: mono ? FONT.mono : FONT.serif,
        fontSize: 34,
        color,
        opacity: o,
        transform: `scale(${mix(0.94, 1, o)})`,
        boxShadow: glow > 0 && children ? `0 0 ${36 * glow}px ${ROLE.plan}` : "none",
      }}
    >
      {children}
    </div>
  );
  return (
    <>
      {stack > 0 && panel(0, -32 * stack, 48, 0.35 * stack, "b2")}
      {stack > 0 && panel(0, -16 * stack, 24, 0.6 * stack, "b1")}
      {panel(0, 0, 0, 1, "front", label)}
    </>
  );
};

type Step = { text: string; color: string; at: number; w: number; mono?: boolean; sub?: string };

/** The recap: four steps in a row, each an empty dashed slot from `slots` that fills at its own `at`.
 *  `y` is the row's centre line. */
const Strip: React.FC<{ y: number; slots: number; steps: Step[] }> = ({ y, slots, steps }) => {
  const { frame, fps } = useScene();
  const o = useAppear(slots, undefined, 0.5);
  if (o <= 0) return null;
  const h = 120;
  return (
    <div style={{ position: "absolute", left: 960, top: y, transform: "translate(-50%, -50%)", display: "flex", alignItems: "center", gap: 18, opacity: o }}>
      {steps.map((st, i) => {
        const p = prog(frame, st.at, 0.5, fps);
        const sp = prog(frame, st.at + Math.round(0.35 * fps), 0.5, fps);
        return (
          <React.Fragment key={i}>
            {i > 0 && <span style={{ fontFamily: FONT.mono, fontSize: 36, color: C.dim, opacity: mix(0.25, 1, p) }}>→</span>}
            <div style={{ position: "relative", width: st.w, height: h }}>
              <div style={{ position: "absolute", inset: 0, borderRadius: 16, border: `2.5px dashed ${C.dim}`, opacity: 0.6 * (1 - p) }} />
              <div
                style={{
                  position: "absolute",
                  inset: 0,
                  boxSizing: "border-box",
                  borderRadius: 16,
                  border: `3px solid ${st.color}`,
                  background: `${st.color}16`,
                  opacity: p,
                  transform: `scale(${mix(0.94, 1, p)})`,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  textAlign: "center",
                  padding: "0 22px",
                  fontFamily: st.mono ? FONT.mono : FONT.serif,
                  fontSize: st.mono ? 32 : 34,
                  lineHeight: 1.2,
                  color: st.color,
                }}
              >
                {st.text}
              </div>
              {st.sub && (
                <div
                  style={{
                    position: "absolute",
                    left: "50%",
                    top: h + 14,
                    transform: `translate(-50%, ${(1 - sp) * 8}px)`,
                    fontFamily: FONT.serif,
                    fontStyle: "italic",
                    fontSize: 28,
                    color: C.dim,
                    whiteSpace: "nowrap",
                    opacity: sp,
                  }}
                >
                  {st.sub}
                </div>
              )}
            </div>
          </React.Fragment>
        );
      })}
    </div>
  );
};

/** A chip naming another video in the series. */
const VideoChip: React.FC<{ text: string; color: string; dots?: string[] }> = ({ text, color, dots }) => (
  <div
    style={{
      display: "flex",
      alignItems: "center",
      gap: 14,
      fontFamily: FONT.serif,
      fontSize: 36,
      color,
      border: `3px solid ${color}`,
      borderRadius: 999,
      padding: "6px 30px",
      background: `${color}14`,
      whiteSpace: "nowrap",
    }}
  >
    {dots && (
      <span style={{ display: "flex", gap: 6 }}>
        {dots.map((d, i) => (
          <span key={i} style={{ width: 14, height: 14, borderRadius: 999, background: d, display: "inline-block" }} />
        ))}
      </span>
    )}
    {text}
  </div>
);

export const Continuous: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const campaign = cue("the campaign shape");
  const twoImpl = cue("two implementations");
  const oneBuild = cue("one build");
  const sameSpec = cue("the same spec");
  const continuous = cue("the continuous shape");
  const type = cue("Put it in a type");
  const mark = cue("mark it continuous");
  const watch = cue("naming the implementation");
  const records = cue("records");
  const plan = cue("as a plan");
  const replays = cue("replays");
  const every = cue("every branch");
  const clear = cue("the one thing you write");
  const stamp = cue("Paste and stamp");
  const amend = cue("Amend what a signature");
  const baselined = cue("Let the test pick");
  const check = cue("check each port");
  const three = cue("Three lines");
  const seams = cue("the seams video");
  const verdicts = cue("the verdicts video");

  // The table: centred until the card arrives, then it moves right to make room.
  const tableX = track(frame, fps, [[0, 960], [type, 1400]]);
  const tableY = track(frame, fps, [[0, 520], [type, 300]]);
  const back = mix(1, 0.45, prog(frame, continuous, 0.6, fps));
  const campLit = [campaign, twoImpl, oneBuild].map((f) => prog(frame, f, 0.5, fps) * back);
  const contLit = [0, 0.25, 0.5].map((d) => prog(frame, continuous + s(d), 0.5, fps));

  // The plan chip: out of main on "plan", across on "replays", down into the branch.
  const chipIn = prog(frame, plan, 0.6, fps);
  const travel = prog(frame, replays + s(0.15), 0.8, fps);
  const drop = prog(frame, replays + s(0.95), 0.45, fps);
  const chipX = mix(MAIN.x, BRANCH.x, travel);
  const chipY = mix(mix(MAIN.y, CHIP_Y, chipIn), BRANCH.y, drop);
  const chipO = frame < plan ? 0 : chipIn * (1 - drop) * visibility(frame, fps, undefined, clear);
  const chipScale = mix(0.6, 1, chipIn) * mix(1, 0.5, drop);

  const stripY = track(frame, fps, [[0, 540], [three, 250]]);
  const steps: Step[] = [
    { text: "stamp the protocol", color: C.text, at: stamp, w: 360 },
    { text: "amend what a signature can't say", color: ROLE.seam, at: amend, w: 440 },
    { text: ".baselined(on:)", color: ROLE.baseline, at: baselined, w: 340, mono: true, sub: "the test picks the baseline" },
    { text: "check(_:)", color: ROLE.candidate, at: check, w: 280, mono: true, sub: "each port" },
  ];

  return (
    <>
      <ShapesTable
        x={tableX}
        y={tableY}
        opacity={useAppear(0, clear)}
        spec={prog(frame, sameSpec, 0.5, fps)}
        cols={[
          { title: "Campaign", rows: ["two implementations", "one build"], lit: campLit, emphasis: campLit[0] },
          { title: "Continuous", rows: ["one implementation", "two builds"], lit: contLit, emphasis: contLit[0] },
        ]}
      />

      {/* The spec in a type, marked continuous, naming the implementation to watch. */}
      <CodeCard
        x={CARD.x}
        y={CARD.y}
        w={CARD.w}
        file="CartMigrationSpec.swift"
        lines={CONTINUOUS}
        color={C.text}
        size={CARD.size}
        at={type + s(0.3)}
        out={clear}
        marks={[{ line: 0, at: mark, color: C.text }]}
      />
      <Svg>
        <Box x={WATCH.x} y={WATCH.y} w={WATCH.w} h={WATCH.h} r={8} width={3} color={ROLE.baseline} fill={`${ROLE.baseline}1A`} at={watch} out={clear} dur={0.5} />
      </Svg>
      <Text x={WATCH.x} y={CARD_TOP - 40} size={28} italic color={ROLE.baseline} at={watch + s(0.2)} out={clear} reveal="fade">
        implementation to watch
      </Text>

      {/* Records on main, replays on every branch. */}
      <Svg>
        <Arrow from={[MAIN.x + MAIN.w / 2 + 12, MAIN.y]} to={[BRANCH.x - BRANCH.w / 2 - 14, BRANCH.y]} at={replays} out={clear} dur={0.6} color={ROLE.plan} width={3} />
      </Svg>
      <Build {...MAIN} label="main" mono color={ROLE.baseline} at={records} out={clear} />
      <Build
        {...BRANCH}
        label="your branch"
        color={ROLE.candidate}
        at={replays}
        out={clear}
        stack={prog(frame, every, 0.6, fps)}
        glow={drop * (1 - 0.6 * prog(frame, replays + s(1.6), 0.8, fps))}
      />
      {chipO > 0 && (
        <div
          style={{
            position: "absolute",
            left: chipX,
            top: chipY,
            transform: `translate(-50%, -50%) scale(${chipScale})`,
            fontFamily: FONT.mono,
            fontSize: 26,
            color: ROLE.plan,
            border: `2.5px solid ${ROLE.plan}`,
            borderRadius: 10,
            padding: "4px 18px",
            background: `linear-gradient(${ROLE.plan}1E, ${ROLE.plan}1E), ${C.bg}`,
            whiteSpace: "nowrap",
            opacity: chipO,
          }}
        >
          Cart.plan.json.gz
        </div>
      )}
      <Text x={MAIN.x} y={VERBS_Y} size={28} italic color={C.dim} at={records + s(0.2)} out={clear} reveal="fade">
        records
      </Text>
      <Text x={(MAIN.x + BRANCH.x) / 2} y={VERBS_Y} size={28} italic color={C.dim} at={replays + s(0.2)} out={clear} reveal="fade">
        replays
      </Text>
      <Text x={BRANCH.x} y={VERBS_Y} size={28} italic color={C.dim} at={every} out={clear} reveal="fade">
        every branch
      </Text>

      {/* The one thing you write. */}
      <Strip y={stripY} slots={clear + s(0.4)} steps={steps} />

      {/* Three lines, for a cart. */}
      <CodeCard
        x={960}
        y={620}
        w={1520}
        file="CartMigrationSpec.swift"
        lines={SPEC}
        color={C.text}
        size={28}
        at={three + s(0.3)}
        marks={[1, 2, 3].map((line, i) => ({ line, at: three + s(0.7 + i * 0.2), color: ROLE.seam }))}
      />

      <Fade x={1440} y={905} anchor="center" at={seams} rise={30}>
        <VideoChip text="Seams" color={ROLE.seam} />
      </Fade>
      <Fade x={1690} y={905} anchor="center" at={verdicts} rise={30}>
        <VideoChip text="Verdicts" color={C.text} dots={Object.values(VERDICT).map((v) => v.color)} />
      </Fade>
    </>
  );
};
