import React from "react";
import { useScene, Svg, Line, Box, C, FONT, MONO_ADVANCE, prog, track, mix } from "#kit";
import { CodeCard, Ordering, ROLE, Verdict, useAppear } from "./shared";

// The protocol is scene 2's simplified Cart (initializer arguments elided), rewrapped at two commas so it
// fits the recall width. The ladder values, `Product.sku ∈ …` and the qualification's format come from
// the brief (Qualification.swift); the qualification's values and the lane run are illustrative.

const CARD = [
  "@Haruspec",
  "protocol Cart: AnyObject {",
  "    init(inventory: …,",
  "         notificationCenter: NotificationCenter, …)",
  "    func add(_ product: Product!,",
  "             quantity: Int) async",
  "    func removeSku(_ sku: String!) async",
  "    func applyPromo(_ code: String!) async -> Bool",
  "    func checkout() async -> Receipt!",
  "    var itemCount: Int { get async }",
  "    var subtotalCents: Int { get async }",
  "}",
];

// CodeCard's geometry, so highlights and connectors can be placed by line and column.
const CARD_X = 420;
const CARD_W = 680;
const CARD_Y = 560;
const CARD_SIZE = 20;
const LH = CARD_SIZE * 1.55;
const CARD_H = 52 + CARD.length * LH + 36;
const CARD_TOP = CARD_Y - CARD_H / 2;
const CARD_L = CARD_X - CARD_W / 2;
const CARD_R = CARD_X + CARD_W / 2;
const CODE_L = CARD_L + 27;
const ADV = CARD_SIZE * MONO_ADVANCE;
const lineTop = (i: number) => CARD_TOP + 75 + i * LH;
const lineMid = (i: number) => lineTop(i) + LH / 2;

// The table (phase 1): columns and their text starts.
const COL = { req: 854, op: 1124, arg: 1414, arrow: 1556, dom: 1594 };
const MONO26 = 26 * MONO_ADVANCE;

// The lanes (phase 2): a bar at x 980, content from x 1000; four operation columns shared by the lanes.
const BAR_X = 980;
const COLS = [1095, 1290, 1485, 1680];
const OPS = ["removeSku", "add", "applyPromo", "checkout"];
const RETURNS = ["→ ()", "→ ()", "→ false", "→ receipt"];
const ZERO_Y = 900;
const SNAP = [0, 2, 2, 0];
const snapX = (i: number) => COLS[i] + 95;
const snapY = (i: number) => ZERO_Y - SNAP[i] * 40;

/** A line of text, left-anchored by default, vertically centred on `y`. `write` reveals it left to right. */
const T: React.FC<{
  x: number;
  y: number;
  children: React.ReactNode;
  size?: number;
  color?: string;
  mono?: boolean;
  italic?: boolean;
  weight?: number;
  at?: number;
  out?: number;
  dur?: number;
  write?: boolean;
  align?: "left" | "center" | "right";
  opacity?: number;
  style?: React.CSSProperties;
}> = ({ x, y, children, size = 26, color = C.text, mono = false, italic = false, weight, at, out, dur = 0.5, write = false, align = "left", opacity = 1, style }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, write ? 0.2 : dur);
  if (o <= 0) return null;
  const w = write && at !== undefined ? prog(frame, at, dur, fps) : 1;
  const tx = align === "left" ? "0" : align === "center" ? "-50%" : "-100%";
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(${tx}, -50%)`,
        fontFamily: mono ? FONT.mono : FONT.serif,
        fontStyle: italic ? "italic" : undefined,
        fontWeight: weight,
        fontSize: size,
        lineHeight: 1.25,
        color,
        whiteSpace: "pre",
        opacity: o * opacity,
        clipPath: w < 1 ? `inset(0 ${(1 - w) * 100}% 0 0)` : undefined,
        ...style,
      }}
    >
      {children}
    </div>
  );
};

/** A highlight behind the protocol card's line (or a column range of it); it shows through the card. */
const Hi: React.FC<{ line: number; lines?: number; from?: number; to?: number; at: number; out?: number; color?: string }> = ({ line, lines = 1, from, to, at, out, color = C.text }) => {
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  const left = from === undefined ? CARD_L + 14 : CODE_L + from * ADV - 4;
  const width = from === undefined ? CARD_W - 28 : ((to ?? from) - from) * ADV + 8;
  return <div style={{ position: "absolute", left, top: lineTop(line) + 1, width, height: lines * LH - 2, borderRadius: 6, background: `${color}${color === C.text ? "22" : "3A"}`, opacity: o }} />;
};

/** A soft highlight behind a table cell. `x` is its left edge, `y` its centre. */
const Spot: React.FC<{ x: number; y: number; w: number; h?: number; color: string; at: number; out?: number }> = ({ x, y, w, h = 42, color, at, out }) => {
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  return <div style={{ position: "absolute", left: x, top: y - h / 2, width: w, height: h, borderRadius: 8, background: `${color}2C`, opacity: o }} />;
};

/** A small mono pill. `x` is its left edge (or centre with `align="center"`), `y` its centre. */
const Chip: React.FC<{ x: number; y: number; text: string; color: string; border?: string; at: number; out?: number; size?: number; align?: "left" | "center" }> = ({
  x,
  y,
  text,
  color,
  border,
  at,
  out,
  size = 26,
  align = "left",
}) => {
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(${align === "left" ? "0" : "-50%"}, -50%) scale(${mix(0.85, 1, Math.min(1, o))})`,
        transformOrigin: align === "left" ? "left center" : "center",
        fontFamily: FONT.mono,
        fontSize: size,
        lineHeight: 1.25,
        color,
        border: `2px solid ${border ?? color}`,
        borderRadius: 999,
        padding: `1px ${Math.round(size * 0.35)}px`,
        background: `${color}12`,
        whiteSpace: "nowrap",
        opacity: o,
      }}
    >
      {text}
    </div>
  );
};

/** A domain the signature can't give: an empty amber cell. `x` is its left edge, `y` its centre. */
const EmptyCell: React.FC<{ x: number; y: number; at: number; out?: number }> = ({ x, y, at, out }) => {
  const o = useAppear(at, out, 0.45);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y - 20,
        width: 150,
        height: 40,
        boxSizing: "border-box",
        border: `2.5px solid ${ROLE.cannotVerify}`,
        borderRadius: 8,
        background: `${ROLE.cannotVerify}12`,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: FONT.mono,
        fontSize: 24,
        color: ROLE.cannotVerify,
        opacity: o,
      }}
    >
      <span style={{ opacity: 0.45 }}>?</span>
    </div>
  );
};

// The magnitude ladder: a half number line from 0 out to 10,000 (± both ways), one rung per power of
// ten with its neighbours either side. Labels alternate above and below the axis so they never collide.
const LADDER = { top: 565, h: 165, axis: 658, l: 920, r: 1822, above: 618, below: 700 };
const RUNGS: { x: number; tokens: string[]; main: number; above: boolean; right?: boolean }[] = [
  { x: 920, tokens: ["0"], main: 0, above: true },
  { x: 1098, tokens: ["±1"], main: 0, above: false },
  { x: 1276, tokens: ["±9", "±10", "±11"], main: 1, above: true },
  { x: 1454, tokens: ["±99", "±100", "±101"], main: 1, above: false },
  { x: 1632, tokens: ["±999", "±1,000", "±1,001"], main: 1, above: true },
  { x: 1810, tokens: ["±9,999", "±10,000"], main: 1, above: false, right: true },
];

const Ladder: React.FC<{ at: number; out: number; steps: number[]; sides: number[]; pulseAt: number }> = ({ at, out, steps, sides, pulseAt }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.5);
  if (o <= 0) return null;
  const pulse = prog(frame, pulseAt, 0.35, fps) * (1 - prog(frame, pulseAt + Math.round(1.2 * fps), 0.6, fps));
  const litAt = (ri: number, k: number) => (k === RUNGS[ri].main ? steps[ri] : sides[ri]);
  return (
    <>
      <div
        style={{
          position: "absolute",
          left: 840,
          top: LADDER.top,
          width: 1000,
          height: LADDER.h,
          boxSizing: "border-box",
          borderRadius: 14,
          border: `2px solid ${C.faint}`,
          background: C.sunken,
          opacity: o,
        }}
      />
      <T x={862} y={LADDER.top + 26} mono color={ROLE.seam} at={at} out={out}>
        Int
      </T>
      <Svg opacity={o}>
        <Line from={[LADDER.l, LADDER.axis]} to={[LADDER.r, LADDER.axis]} at={at} dur={0.6} color={C.dim} width={2} />
        {RUNGS.flatMap((r, ri) =>
          r.tokens.map((_, k) => {
            const x = r.x + (k - r.main) * 9;
            const main = k === r.main;
            const lit = prog(frame, litAt(ri, k), 0.3, fps);
            const half = main ? 12 : mix(6, 12, lit) + pulse * 5;
            return (
              <g key={`${ri}-${k}`}>
                <line x1={x} y1={LADDER.axis - 7} x2={x} y2={LADDER.axis + 7} stroke={C.faint} strokeWidth={2.5} />
                <line x1={x} y1={LADDER.axis - half} x2={x} y2={LADDER.axis + half} stroke={ROLE.seam} strokeWidth={main ? 3 : 2.5} opacity={lit} />
              </g>
            );
          }),
        )}
      </Svg>
      {RUNGS.map((r, ri) => (
        <div
          key={ri}
          style={{
            position: "absolute",
            left: r.right ? 1832 : r.x,
            top: r.above ? LADDER.above : LADDER.below,
            transform: `translate(${r.right ? "-100%" : "-50%"}, -50%)`,
            fontFamily: FONT.mono,
            fontSize: 26,
            lineHeight: 1.25,
            color: ROLE.seam,
            whiteSpace: "pre",
            opacity: o,
          }}
        >
          {r.tokens.map((tok, k) => {
            const lit = prog(frame, litAt(ri, k), 0.35, fps);
            const side = k !== r.main;
            return (
              <React.Fragment key={k}>
                {k > 0 ? " " : ""}
                <span style={{ opacity: lit, textShadow: side && pulse > 0 ? `0 0 ${16 * pulse}px ${ROLE.seam}` : "none" }}>{tok}</span>
              </React.Fragment>
            );
          })}
        </div>
      ))}
    </>
  );
};

/** A lane beside the protocol card: a bar and a title, dim until the narration names it. */
const Lane: React.FC<{ top: number; bottom: number; titleY: number; title: string; at: number; named: number }> = ({ top, bottom, titleY, title, at, named }) => {
  const { frame, fps } = useScene();
  const lit = prog(frame, named, 0.4, fps);
  return (
    <>
      <Svg>
        <Line from={[BAR_X, top]} to={[BAR_X, bottom]} at={at} dur={0.5} color={C.dim} width={4} opacity={mix(0.5, 1, lit)} />
      </Svg>
      <T x={1000} y={titleY} size={30} italic at={at} opacity={mix(0.45, 1, lit)}>
        {title}
      </T>
    </>
  );
};

export const Derived: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  // Phase 1: the catalog.
  const catalog = cue("catalog");
  const sigs = cue("signatures");
  const methods = cue("every method");
  const args = cue("every argument");
  const domains = cue("a domain from its type");
  const ladder = cue("ladder of magnitudes");
  const mags = cue("magnitudes");
  const sideAt = cue("either side");
  const offBy = cue("bugs live", { offset: -0.8 });
  const bool = cue("both values");
  const product = cue("product");
  const gen = cue("its own generator");
  const repeats = cue("zero to three times");
  const emptyAt = cue("even a checkout");
  const emptyCart = cue("empty cart");
  const chose = cue("the engine chose");
  const marked = cue("is marked");
  const verdict = cue("on the verdict");
  const green = cue("a green");
  // Phase 2: the effects.
  const effects = cue("effects worth observing");
  const paste = cue("same paste");
  const calls = cue("calls and returns");
  const returns = cue("returns");
  const forwarder = cue("forwarder");
  const notes = cue("notifications");
  const initializer = cue("initializer");
  const props = cue("each property");
  const read = cue("read after every operation");
  const pathAt = cue("the path is compared");
  const ended = cue("where it ended");

  const out1 = effects;
  const bump = (a: number, b: number) => prog(frame, a, 0.4, fps) * (1 - prog(frame, b, 0.6, fps));
  const glow = 0.6 * Math.max(bump(sigs, methods), bump(paste, calls));
  const greenGlow = 0.8 * bump(green, green + s(1.4));

  const rowAt = [0, 1, 2, 3].map((i) => methods + s(i * 0.35));
  const argAt = [0, 1, 2, 3].map((i) => args + s(i * 0.25));
  const domAt = [0, 1, 2, 3, 4].map((i) => domains + s(i * 0.22));
  const steps = RUNGS.map((_, i) => mags + s(i * 0.32));
  const sides = RUNGS.map((_, i) => sideAt + s(Math.max(0, i - 2) * 0.3));
  const tickAt = COLS.map((_, i) => read + s(i * 0.35));
  const dotAt = tickAt.map((t) => t + s(0.18));

  // The product cell expands at "its own generator"; the rows below glide down to make room.
  const ex = track(frame, fps, [[0, 0], [gen, 76]], 0.6);
  const yProduct = 244;
  const yQuantity = 288 + ex;
  const ROWS = [
    { req: "add(_:quantity:)", op: "add", y: yProduct },
    { req: "removeSku(_:)", op: "removeSku", y: 354 + ex },
    { req: "applyPromo(_:)", op: "applyPromo", y: 426 + ex },
    { req: "checkout()", op: "checkout", y: 498 + ex },
  ];
  const seps = [318 + ex, 390 + ex, 462 + ex, 534 + ex];
  const ARGS = [
    { name: "product", y: yProduct },
    { name: "quantity", y: yQuantity },
    { name: "sku", y: ROWS[1].y },
    { name: "code", y: ROWS[2].y },
  ];

  const pathP = prog(frame, pathAt + s(0.2), 0.9, fps);
  const ringP = prog(frame, ended, 0.6, fps);
  const funcMid = (lineTop(4) + lineTop(9)) / 2;
  const varMid = (lineTop(9) + lineTop(11)) / 2;

  return (
    <>
      {/* Highlights behind the protocol card. Phase 1: each method as its row writes, then each argument's type. */}
      <Hi line={4} lines={2} at={rowAt[0]} out={domAt[0]} />
      <Hi line={6} at={rowAt[1]} out={domAt[0]} />
      <Hi line={7} at={rowAt[2]} out={domAt[0]} />
      <Hi line={8} at={rowAt[3]} out={domAt[0]} />
      <Hi line={4} from={15} to={32} at={domAt[0]} out={out1} color={ROLE.seam} />
      <Hi line={5} from={13} to={26} at={domAt[1]} out={out1} color={ROLE.seam} />
      <Hi line={6} from={21} to={33} at={domAt[2]} out={out1} color={ROLE.cannotVerify} />
      <Hi line={7} from={22} to={35} at={domAt[3]} out={out1} color={ROLE.cannotVerify} />
      {/* Phase 2: the lines each lane reads from. */}
      <Hi line={4} lines={5} at={calls} />
      <Hi line={3} from={9} to={47} at={notes} />
      <Hi line={2} from={4} to={8} at={initializer} />
      <Hi line={9} lines={2} at={props} />

      <CodeCard x={CARD_X} y={CARD_Y} w={CARD_W} file="SubjectBoundaries.swift" lines={CARD} color={C.text} size={CARD_SIZE} glow={glow} />
      <T x={CARD_X} y={CARD_TOP + CARD_H + 32} align="center" italic color={C.dim}>
        simplified
      </T>

      {/* ── Phase 1: the catalog table ── */}
      <T x={840} y={142} size={34} at={catalog} out={out1}>
        catalog
      </T>
      <T x={COL.req} y={188} italic color={C.dim} at={catalog + s(0.3)} out={out1}>
        requirement
      </T>
      <T x={COL.op} y={188} italic color={C.dim} at={catalog + s(0.4)} out={out1}>
        operation
      </T>
      <T x={COL.arg} y={188} italic color={C.dim} at={catalog + s(0.5)} out={out1}>
        argument → domain
      </T>
      <Svg>
        <Line from={[840, 212]} to={[1840, 212]} at={catalog} out={out1} color={C.dim} width={2} dur={0.6} />
        {seps.map((y, i) => (
          <Line key={i} from={[840, y]} to={[1840, y]} at={rowAt[i]} out={out1} color={C.faint} width={1.5} dur={0.5} />
        ))}
      </Svg>

      {/* Cell highlights sit behind the cell text. */}
      <Spot x={COL.dom - 8} y={yQuantity} w={232} color={ROLE.seam} at={ladder} out={product} />
      <Spot x={COL.arg - 8} y={yProduct} w={126} color={ROLE.seam} at={product} out={out1} />

      {ROWS.map((r, i) => (
        <React.Fragment key={r.op}>
          <T x={COL.req} y={r.y} mono at={rowAt[i]} out={out1} write dur={0.5}>
            {r.req}
          </T>
          <T x={COL.op} y={r.y} mono weight={600} at={rowAt[i] + s(0.25)} out={out1} write dur={0.4}>
            {r.op}
          </T>
        </React.Fragment>
      ))}
      {ARGS.map((a, i) => (
        <React.Fragment key={a.name}>
          <T x={COL.arg} y={a.y} mono at={argAt[i]} out={out1} write dur={0.35}>
            {a.name}
          </T>
          <T x={COL.arrow} y={a.y} mono color={C.dim} at={argAt[i] + s(0.2)} out={out1}>
            →
          </T>
        </React.Fragment>
      ))}
      <T x={COL.dom} y={yProduct} size={28} color={ROLE.seam} at={domAt[0]} out={out1} write>
        its own generator
      </T>
      <T x={COL.dom} y={yQuantity} size={28} color={ROLE.seam} at={domAt[1]} out={out1} write>
        magnitude ladder
      </T>
      <EmptyCell x={COL.dom} y={ROWS[1].y} at={domAt[2]} out={out1} />
      <EmptyCell x={COL.dom} y={ROWS[2].y} at={domAt[3]} out={out1} />
      <T x={COL.arg} y={ROWS[3].y} size={28} italic color={C.dim} at={domAt[4]} out={out1}>
        no arguments
      </T>

      {/* A whole number: the magnitude ladder. A Boolean: both values. */}
      <Ladder at={ladder} out={product} steps={steps} sides={sides} pulseAt={offBy} />
      <Chip x={1660} y={790} align="center" text="Bool → false, true" color={ROLE.seam} at={bool} out={product} />

      {/* A model: the product cell expands to its generator. */}
      <Svg>
        <Line from={[COL.arg - 12, 266]} to={[COL.arg - 12, 340]} at={gen + s(0.5)} out={out1} color={ROLE.seam} width={3} dur={0.4} />
      </Svg>
      <T x={COL.arg} y={284} mono color={ROLE.seam} at={gen + s(0.5)} out={out1} write dur={0.5}>
        Product.sku ∈
      </T>
      <T x={COL.arg} y={322} mono color={ROLE.seam} at={gen + s(0.85)} out={out1} write dur={0.8}>
        BEANS, COFFEE, FILTER, MUG
      </T>

      {/* Each operation repeats zero to three times; an ordering of checkout alone is an empty cart. */}
      {ROWS.slice(0, 3).map((r, i) => (
        <Chip key={r.op} x={COL.op + r.op.length * MONO26 + 14} y={r.y} text="× 0…3" color={C.text} border={C.dim} at={repeats + s(i * 0.15)} out={out1} />
      ))}
      <Ordering x={COL.req} y={680} ops={["checkout"]} at={emptyAt} out={out1} />
      <T x={1036} y={680} size={28} italic color={C.dim} at={emptyCart} out={out1}>
        an empty cart
      </T>

      {/* A domain the engine chose is marked on the verdict. */}
      <Svg>
        <Box x={COL.dom + 106} y={yQuantity} w={232} h={48} r={10} at={chose} out={out1} color={ROLE.seam} dashed width={2} fill={`${C.bg}00`} />
      </Svg>
      <Verdict x={990} y={800} kind="equivalent" size={28} at={verdict} out={out1} glow={greenGlow} />
      <T x={COL.req} y={868} mono at={marked} out={out1} write dur={1.2}>
        seams: add.quantity (3 positions · <span style={{ color: ROLE.seam }}>derived default</span>)
      </T>
      <T x={COL.req} y={912} italic color={C.dim} at={marked + s(0.9)} out={out1}>
        values illustrative
      </T>

      {/* ── Phase 2: three lanes of effects, each linked to the lines it reads ── */}
      <Lane top={290} bottom={400} titleY={312} title="notifications" at={effects + s(0.6)} named={notes} />
      <Lane top={480} bottom={650} titleY={502} title="calls and returns" at={effects + s(0.75)} named={calls} />
      <Lane top={700} bottom={960} titleY={722} title="properties" at={effects + s(0.9)} named={props} />
      <T x={1840} y={250} align="right" italic color={C.dim} at={calls}>
        illustrative run
      </T>

      <Svg>
        {/* calls and returns ← the func lines */}
        <Line from={[CARD_R + 12, lineTop(4) + 4]} to={[CARD_R + 12, lineTop(9) - 4]} at={calls} dur={0.3} color={C.dim} width={3} />
        <Line from={[CARD_R + 12, funcMid]} to={[BAR_X - 6, 565]} at={calls + s(0.2)} dur={0.5} color={C.dim} width={2} />
        {/* notifications ← the center the initializer takes */}
        <Line from={[CARD_R + 6, lineMid(3)]} to={[BAR_X - 6, 345]} at={notes} dur={0.5} color={C.dim} width={2} />
        {/* properties ← the var lines */}
        <Line from={[CARD_R + 12, lineTop(9) + 4]} to={[CARD_R + 12, lineTop(11) - 4]} at={props} dur={0.3} color={C.dim} width={3} />
        <Line from={[CARD_R + 12, varMid]} to={[BAR_X - 6, 830]} at={props + s(0.2)} dur={0.5} color={C.dim} width={2} />
      </Svg>

      {/* calls and returns, at the forwarder */}
      <T x={1262} y={502} size={28} italic color={C.dim} at={forwarder}>
        via
      </T>
      <Chip x={1310} y={502} text="TracedCart" color={C.text} border={C.dim} at={forwarder} />
      {OPS.map((op, i) => (
        <Chip key={op} x={COLS[i]} y={562} align="center" text={op} color={C.text} border={`${C.text}88`} at={calls + s(0.3 + i * 0.15)} />
      ))}
      {RETURNS.map((r, i) => (
        <T key={i} x={COLS[i]} y={610} mono align="center" color={C.dim} at={returns + s(i * 0.12)}>
          {r}
        </T>
      ))}

      {/* notifications, posted during a call (illustrative) */}
      <Svg>
        {[1, 3].map((c, i) => {
          const o = prog(frame, notes + s(0.45 + i * 0.25), 0.35, fps);
          if (o <= 0) return null;
          const x = COLS[c];
          return <rect key={c} x={x - 10} y={368 - 10} width={20} height={20} fill={C.text} opacity={o} transform={`rotate(45 ${x} 368)`} />;
        })}
      </Svg>

      {/* properties, read after every operation; the path is compared, not just the end state */}
      <T x={1165} y={722} mono color={C.dim} at={read}>
        itemCount
      </T>
      <T x={1840} y={722} align="right" italic color={C.dim} at={read}>
        illustrative
      </T>
      <Svg>
        <Line from={[1010, ZERO_Y]} to={[1820, ZERO_Y]} at={read} dur={0.6} color={C.faint} width={2} />
        {COLS.map((x, i) => (
          <Line key={i} from={[x, ZERO_Y - 14]} to={[x, ZERO_Y + 14]} at={tickAt[i]} dur={0.2} color={C.dim} width={3} />
        ))}
        {pathP > 0 && (
          <path
            d={SNAP.map((_, i) => `${i === 0 ? "M" : "L"}${snapX(i)} ${snapY(i)}`).join(" ")}
            fill="none"
            stroke={C.text}
            strokeWidth={4}
            strokeLinejoin="round"
            pathLength={1}
            strokeDasharray="1 2"
            strokeDashoffset={1 - pathP}
          />
        )}
        {SNAP.map((_, i) => {
          const p = prog(frame, dotAt[i], 0.3, fps);
          if (p <= 0) return null;
          return <circle key={i} cx={snapX(i)} cy={snapY(i)} r={9 * mix(0.4, 1, p)} fill={C.text} opacity={p} />;
        })}
        {ringP > 0 && (
          <circle
            cx={snapX(3)}
            cy={snapY(3)}
            r={22}
            fill="none"
            stroke={C.text}
            strokeWidth={2.5}
            pathLength={1}
            strokeDasharray="1 2"
            strokeDashoffset={1 - ringP}
            transform={`rotate(-90 ${snapX(3)} ${snapY(3)})`}
          />
        )}
      </Svg>
      {SNAP.map((v, i) => (
        <T key={i} x={snapX(i)} y={snapY(i) - 32} mono align="center" at={dotAt[i]}>
          {String(v)}
        </T>
      ))}
      <T x={snapX(3)} y={ZERO_Y + 46} align="center" italic color={C.dim} at={ended + s(0.2)}>
        end state
      </T>
    </>
  );
};
