import React from "react";
import { useScene, Arrow, Box, Node, Svg, Text, C, FONT, MONO_ADVANCE, mix, prog, track, visibility } from "#kit";
import { CodeCard, Ordering, ROLE, Verdict } from "./shared";

// The pictures are illustrative of what the engine does, drawn on the dogfood cart (CartManager,
// SwiftCart): the reads, the grid's orderings and variants, the shrink factor, the middle values and
// the shrinking ordering are made up for the picture. The budget box shows the derived defaults; the
// Vary card is quoted from Tests/SpecTests/DerivedOpsTests.swift.

type Rect = [number, number, number, number];

const clamp01 = (v: number) => Math.max(0, Math.min(1, v));

// The shared `Ordering`'s geometry: mono pills with `size / 2` side padding and a 2px border, joined by
// an arrow with a `0.45 × size` gap either side.
const pillW = (op: string, size: number) => op.length * size * MONO_ADVANCE + size + 4;
const spacer = (size: number) => size * 0.9 + size * MONO_ADVANCE;
const rowWidth = (ops: string[], size: number) => ops.reduce((w, op) => w + pillW(op, size), 0) + (ops.length - 1) * spacer(size);
const lefts = (ops: string[], x0: number, size: number) => {
  const xs: number[] = [];
  let x = x0;
  for (const op of ops) {
    xs.push(x);
    x += pillW(op, size) + spacer(size);
  }
  return xs;
};
const centred = (ops: string[], size: number, cx: number) => lefts(ops, cx - rowWidth(ops, size) / 2, size);

/** A value chip (one or two lines of mono), centred on `x`/`y`. */
const Chip: React.FC<{ x: number; y: number; lines: string[]; color: string; opacity: number; size?: number; dashed?: boolean }> = ({
  x,
  y,
  lines,
  color,
  opacity,
  size = 26,
  dashed = false,
}) => {
  if (opacity <= 0) return null;
  const two = lines.length > 1;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translate(-50%, -50%)",
        opacity,
        fontFamily: FONT.mono,
        fontSize: size,
        lineHeight: `${Math.round(size * 1.25)}px`,
        fontVariantLigatures: "none",
        color,
        border: `2.5px ${dashed ? "dashed" : "solid"} ${color}`,
        borderRadius: two ? 16 : 999,
        padding: two ? "8px 18px" : "3px 15px",
        background: `${color}14`,
        whiteSpace: "pre",
        textAlign: "center",
      }}
    >
      {lines.map((l, i) => (
        <div key={i}>{l}</div>
      ))}
    </div>
  );
};

/** A short label anchored by its left edge, centre or right edge. */
const Label: React.FC<{ x: number; y: number; text: string; opacity: number; align?: "left" | "center" | "right"; size?: number; color?: string; italic?: boolean }> = ({
  x,
  y,
  text,
  opacity,
  align = "center",
  size = 28,
  color = C.dim,
  italic = true,
}) => {
  if (opacity <= 0) return null;
  const tx = align === "left" ? "0" : align === "center" ? "-50%" : "-100%";
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(${tx}, -50%)`,
        opacity,
        fontFamily: FONT.serif,
        fontStyle: italic ? "italic" : "normal",
        fontSize: size,
        color,
        whiteSpace: "nowrap",
      }}
    >
      {text}
    </div>
  );
};

// ── 1 · the original runs once ────────────────────────────────────────────────────────────────────

const RUN = ["add", "removeSku", "applyPromo", "checkout"];
const READS = ["quantity", "sku", "code"]; // what add, removeSku and applyPromo read
const NODE_Y = 175;
const TAPE_Y = 252;
const RUN_X = 400;
const RUN_SIZE = 26;

const RunOnce: React.FC<{ first: number; original: number; runAt: number; tapeAt: number; labelAt: number; lift: number; out: number }> = ({
  first,
  original,
  runAt,
  tapeAt,
  labelAt,
  lift,
  out,
}) => {
  const { frame, fps } = useScene();
  const o = visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  const step = Math.round(0.5 * fps);
  const xs = lefts(RUN, RUN_X, RUN_SIZE);
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, transform: `translateY(${lift}px)`, opacity: o }}>
      <Node x={215} y={NODE_Y} w={270} h={80} label="CartManager" color={ROLE.baseline} at={original} mono size={30} />
      <Text x={215} y={NODE_Y + 76} size={26} italic color={C.dim} at={runAt} reveal="fade">
        runs once
      </Text>
      <Svg>
        <Arrow from={[356, NODE_Y]} to={[392, NODE_Y]} at={original + Math.round(0.4 * fps)} dur={0.3} color={ROLE.baseline} width={3} />
        <Box x={725} y={TAPE_Y} w={790} h={56} r={14} at={tapeAt} color={C.faint} fill={C.sunken} dur={0.6} />
        {RUN.map((op, i) => {
          const t0 = runAt + i * step;
          const on = prog(frame, t0, 0.15, fps) * (1 - prog(frame, t0 + step, 0.2, fps));
          if (frame < t0 || on <= 0) return null;
          return (
            <rect
              key={op}
              x={xs[i] - 8}
              y={NODE_Y - 29}
              width={pillW(op, RUN_SIZE) + 16}
              height={58}
              rx={29}
              fill={`${ROLE.baseline}1A`}
              stroke={ROLE.baseline}
              strokeWidth={3}
              opacity={on}
            />
          );
        })}
      </Svg>
      <Ordering x={RUN_X} y={NODE_Y} ops={RUN} ats={RUN.map((_, i) => first + Math.round(i * 0.12 * fps))} size={RUN_SIZE} />
      {READS.map((v, i) => {
        const d = runAt + i * step + Math.round(0.2 * fps);
        if (frame < d) return null;
        const p = prog(frame, d, 0.55, fps);
        const cx = xs[i] + pillW(RUN[i], RUN_SIZE) / 2;
        return <Chip key={v} x={cx} y={mix(NODE_Y + 24, TAPE_Y, p)} lines={[v]} color={ROLE.seam} opacity={Math.min(1, p * 2.5)} />;
      })}
      <Label x={1150} y={TAPE_Y} text="what the cart reads" opacity={prog(frame, labelAt, 0.5, fps)} align="left" />
    </div>
  );
};

// ── 2 · the grid: orderings × seam variants ───────────────────────────────────────────────────────

const ROWS = [
  ["add", "add", "applyPromo", "checkout"],
  ["applyPromo", "add", "checkout"],
  ["checkout"],
  ["removeSku", "add", "checkout"],
  ["add", "removeSku", "checkout"],
  ["applyPromo", "checkout"],
];
const ROW_FADE = [1, 1, 1, 1, 0.45, 0.2];
const rowY = (r: number) => 450 + r * 90;
const VARIANTS = [["quantity=0", "code=SAVE10"], ["quantity=-1", "code=NOPE"], ["quantity=10000", "code=save10"], ["…"]];
const COL_FADE = [1, 1, 1, 0.45];
const colX = (c: number) => 895 + c * 270;
const CHIP_Y = 345;
const CELL_W = 230;
const CELL_H = 62;
// The grid's extent at full size, and the camera's pull-back about the frame centre.
const GRID: Rect = [80, 300, 1820, 931];
const ZOOM = 0.4;
const K = 0.6; // the illustrative shrink factor, √(budget ÷ full)
const patch = (z: number, pad = 12): Rect => [
  960 + (GRID[0] - 960) * z - pad,
  540 + (GRID[1] - 540) * z - pad,
  960 + (GRID[2] - 960) * z + pad,
  540 + (GRID[3] - 540) * z + pad,
];

const halfPath = (cx: number, cy: number, w: number, h: number, side: -1 | 1, r = 10) => {
  const xe = cx + (side * w) / 2;
  const y0 = cy - h / 2;
  const y1 = cy + h / 2;
  const sweep = side < 0 ? 0 : 1;
  return `M ${cx} ${y0} H ${xe - side * r} A ${r} ${r} 0 0 ${sweep} ${xe} ${y0 + r} V ${y1 - r} A ${r} ${r} 0 0 ${sweep} ${xe - side * r} ${y1} H ${cx} Z`;
};

const Cell: React.FC<{ cx: number; cy: number; fillAt: number; splitAt: number; tickAt: number; fade: number }> = ({ cx, cy, fillAt, splitAt, tickAt, fade }) => {
  const { frame, fps } = useScene();
  if (frame < fillAt) return null;
  const f = prog(frame, fillAt, 0.4, fps) * fade;
  const sp = frame < splitAt ? 0 : prog(frame, splitAt, 0.45, fps);
  const tp = frame < tickAt ? 0 : prog(frame, tickAt, 0.4, fps);
  const len = 36;
  return (
    <g opacity={f}>
      <rect x={cx - CELL_W / 2} y={cy - CELL_H / 2} width={CELL_W} height={CELL_H} rx={10} fill={`${C.text}08`} stroke={C.faint} strokeWidth={2.5} />
      <path d={halfPath(cx, cy, CELL_W, CELL_H, -1)} fill={ROLE.baseline} fillOpacity={0.26 * sp} />
      <path d={halfPath(cx, cy, CELL_W, CELL_H, 1)} fill={ROLE.candidate} fillOpacity={0.26 * sp} />
      <line x1={cx} y1={cy - (CELL_H / 2) * sp} x2={cx} y2={cy + (CELL_H / 2) * sp} stroke={C.dim} strokeWidth={2} opacity={sp} />
      <rect x={cx - CELL_W / 2} y={cy - CELL_H / 2} width={CELL_W} height={CELL_H} rx={10} fill="none" stroke={ROLE.equivalent} strokeWidth={3} opacity={tp} />
      <circle cx={cx} cy={cy} r={18} fill={C.bg} stroke={ROLE.equivalent} strokeWidth={2.5} opacity={tp} />
      <path
        d={`M ${cx - 9} ${cy + 1} L ${cx - 2} ${cy + 8} L ${cx + 10} ${cy - 7}`}
        fill="none"
        stroke={ROLE.equivalent}
        strokeWidth={4}
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeDasharray={len}
        strokeDashoffset={len * (1 - tp)}
        opacity={tp > 0 ? 1 : 0}
      />
    </g>
  );
};

const Grid: React.FC<{ orderings: number; variants: number; fresh: number; bothCarts: number; identical: number; enormous: number; zoom: number; out: number }> = ({
  orderings,
  variants,
  fresh,
  bothCarts,
  identical,
  enormous,
  zoom,
  out,
}) => {
  const { frame, fps } = useScene();
  const o = visibility(frame, fps, undefined, out);
  if (o <= 0 || frame < orderings) return null;
  const s = (sec: number) => Math.round(sec * fps);
  const legend = prog(frame, bothCarts, 0.4, fps) * visibility(frame, fps, undefined, enormous);
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, transformOrigin: "960px 540px", transform: `scale(${zoom})`, opacity: o }}>
      <Label x={80} y={CHIP_Y} text="orderings" opacity={prog(frame, orderings, 0.5, fps)} align="left" />
      {ROWS.map((ops, r) => (
        <div key={r} style={{ opacity: ROW_FADE[r] }}>
          <Ordering x={80} y={rowY(r)} ops={ops} ats={ops.map((_, i) => orderings + s(r * 0.25 + i * 0.07))} />
        </div>
      ))}
      {VARIANTS.map((lines, c) => (
        <Chip
          key={c}
          x={colX(c)}
          y={CHIP_Y}
          lines={lines}
          color={ROLE.seam}
          opacity={frame < variants + s(c * 0.25) ? 0 : prog(frame, variants + s(c * 0.25), 0.45, fps) * COL_FADE[c]}
          dashed={c === VARIANTS.length - 1}
        />
      ))}
      <Svg>
        {ROWS.map((_, r) =>
          VARIANTS.map((__, c) => (
            <Cell
              key={`${r}:${c}`}
              cx={colX(c)}
              cy={rowY(r)}
              fillAt={fresh + s((r + c) * 0.09)}
              splitAt={bothCarts + s((r + c) * 0.07)}
              tickAt={identical + s((r + c) * 0.07)}
              fade={ROW_FADE[r] * COL_FADE[c]}
            />
          )),
        )}
      </Svg>
      <Chip x={1180} y={240} lines={["CartManager"]} color={ROLE.baseline} opacity={legend} />
      <Chip x={1420} y={240} lines={["SwiftCart"]} color={ROLE.candidate} opacity={legend} />
    </div>
  );
};

/** The faint dotted field the grid sits in once the camera pulls back. Dots track the zoom, thin out
 *  towards the margin, and leave `holes` clear for the patch and the labels. */
const Field: React.FC<{ zoom: number; opacity: number; holes: Rect[] }> = ({ zoom, opacity, holes }) => {
  if (opacity <= 0) return null;
  const dots: React.ReactNode[] = [];
  const pitch = 90 * zoom;
  for (let i = -26; i <= 26; i++) {
    for (let j = -14; j <= 14; j++) {
      const x = 960 + i * pitch;
      const y = 540 + j * pitch;
      if (x < 90 || x > 1830 || y < 140 || y > 990) continue;
      if (holes.some(([x0, y0, x1, y1]) => x > x0 && x < x1 && y > y0 && y < y1)) continue;
      const edge = clamp01(Math.min(x - 80, 1840 - x, y - 130, 1000 - y) / 170);
      dots.push(<circle key={`${i}:${j}`} cx={x} cy={y} r={2.4} fill={C.dim} opacity={0.55 * edge} />);
    }
  }
  return <Svg opacity={opacity}>{dots}</Svg>;
};

/** "derived spec · up to 50 orderings · 1,200 runs", each part arriving as it is spoken. */
const BudgetBox: React.FC<{ at: number; runsAt: number; ordersAt: number; out: number }> = ({ at, runsAt, ordersAt, out }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const o = prog(frame, at, 0.5, fps) * visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  const part = (t: number) => (frame < t ? 0 : prog(frame, t, 0.45, fps));
  const seg = (text: string, t: number, weight = 400) => <span style={{ opacity: part(t), fontWeight: weight }}>{text}</span>;
  return (
    <div
      style={{
        position: "absolute",
        left: 960,
        top: 230,
        transform: `translate(-50%, -50%) scale(${mix(0.95, 1, o)})`,
        opacity: o,
        fontFamily: FONT.mono,
        fontSize: 30,
        fontVariantLigatures: "none",
        color: C.text,
        background: C.surface,
        border: `2.5px solid ${C.text}`,
        borderRadius: 14,
        padding: "14px 32px",
        whiteSpace: "pre",
      }}
    >
      {seg("derived spec", at, 600)}
      {seg(" · up to 50 orderings", ordersAt)}
      {seg(" · 1,200 runs", runsAt)}
    </div>
  );
};

// ── 3 · edges first ───────────────────────────────────────────────────────────────────────────────

// Final slot = index; `from` is the slot it starts in. The six edges are the derived ladder's ends and
// the amendment's values; the four middles are illustrative random draws.
const STRIP = [
  { v: "0", from: 3 },
  { v: "±1", from: 6 },
  { v: "±10000", from: 8 },
  { v: "SAVE10", from: 1 },
  { v: "save10", from: 9 },
  { v: "NOPE", from: 4 },
  { v: "42", from: 0 },
  { v: "-317", from: 2 },
  { v: "2861", from: 5 },
  { v: "-75", from: 7 },
];
const EDGES = 6;
const slotX = (i: number) => 240 + i * 160;
const STRIP_CHIP_Y = 420;
const STRIP_ROWS = [510, 586, 662];

const EdgeStrip: React.FC<{ at: number; reorder: number; small: number; middles: number; notEnds: number; out: number }> = ({ at, reorder, small, middles, notEnds, out }) => {
  const { frame, fps } = useScene();
  const s = (sec: number) => Math.round(sec * fps);
  if (frame < at) return null;
  const all = visibility(frame, fps, undefined, out);
  if (all <= 0) return null;
  const middleOut = notEnds + s(0.5);
  return (
    <>
      <Svg>
        {STRIP.map(({ v, from }, i) => {
          const edge = i < EDGES;
          const x0 = slotX(from);
          const x1 = slotX(i);
          const x = track(frame, fps, [[0, x0], [reorder, x1]], 1.0);
          const p = x1 === x0 ? 1 : clamp01((x - x0) / (x1 - x0));
          const dy = (edge ? -1 : 1) * 40 * Math.sin(Math.PI * p);
          const fadeOut = edge ? 1 : visibility(frame, fps, undefined, notEnds + s((STRIP.length - 1 - i) * 0.12));
          const o = prog(frame, at + s(from * 0.04), 0.4, fps) * fadeOut * all;
          if (o <= 0) return null;
          return (
            <g key={v} opacity={o}>
              {STRIP_ROWS.map((ry) => (
                <rect key={ry} x={x - 65} y={ry + dy - 28} width={130} height={56} rx={10} fill={`${C.text}08`} stroke={C.faint} strokeWidth={2.5} />
              ))}
            </g>
          );
        })}
        <Box x={640} y={542} w={970} h={340} r={18} at={small} out={out} color={C.text} width={3} />
      </Svg>
      {STRIP.map(({ v, from }, i) => {
        const edge = i < EDGES;
        const x0 = slotX(from);
        const x1 = slotX(i);
        const x = track(frame, fps, [[0, x0], [reorder, x1]], 1.0);
        const p = x1 === x0 ? 1 : clamp01((x - x0) / (x1 - x0));
        const dy = (edge ? -1 : 1) * 40 * Math.sin(Math.PI * p);
        const fadeOut = edge ? 1 : visibility(frame, fps, undefined, notEnds + s((STRIP.length - 1 - i) * 0.12));
        const o = prog(frame, at + s(from * 0.04), 0.4, fps) * fadeOut * all * (edge ? 1 : 0.75);
        return <Chip key={v} x={x} y={STRIP_CHIP_Y + dy} lines={[v]} color={ROLE.seam} opacity={o} dashed={!edge} />;
      })}
      <Label x={640} y={330} text="edges" color={ROLE.seam} opacity={(frame < reorder + s(0.6) ? 0 : prog(frame, reorder + s(0.6), 0.5, fps)) * all} />
      <Label x={1440} y={330} text="random middles" opacity={(frame < middles ? 0 : prog(frame, middles, 0.5, fps)) * visibility(frame, fps, undefined, middleOut)} />
      <Label x={1440} y={752} text="illustrative" size={26} opacity={(frame < middles ? 0 : prog(frame, middles, 0.5, fps)) * visibility(frame, fps, undefined, middleOut)} />
      <Label x={640} y={752} text="small budget" color={C.text} opacity={(frame < small ? 0 : prog(frame, small, 0.5, fps)) * all} />
    </>
  );
};

// ── 5 · shrinking a red run ───────────────────────────────────────────────────────────────────────

const SHRINK_OPS = ["add", "applyPromo", "add", "removeSku", "checkout"];
const DROPPED = 3;
const SZ = 34;
const ROW_Y = 540;
const MINI_COLS = 10;
const MINI_ROWS = 4;
const RED_CELL = { r: 1, c: 6 };
const miniX = (c: number) => 600 + c * 80;
const miniY = (r: number) => 190 + r * 56;

const MiniGrid: React.FC<{ at: number; redAt: number; out: number }> = ({ at, redAt, out }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const o = visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  const redP = frame < redAt ? 0 : prog(frame, redAt, 0.35, fps);
  const cells: React.ReactNode[] = [];
  for (let r = 0; r < MINI_ROWS; r++) {
    for (let c = 0; c < MINI_COLS; c++) {
      const p = prog(frame, at + Math.round((r + c) * 0.025 * fps), 0.35, fps);
      const isRed = r === RED_CELL.r && c === RED_CELL.c;
      cells.push(
        <g key={`${r}:${c}`} opacity={p}>
          <rect x={miniX(c) - 32} y={miniY(r) - 20} width={64} height={40} rx={8} fill={`${ROLE.equivalent}22`} stroke={ROLE.equivalent} strokeWidth={2} />
          {isRed && redP > 0 && (
            <>
              <rect x={miniX(c) - 40} y={miniY(r) - 28} width={80} height={56} rx={12} fill="none" stroke={ROLE.diverged} strokeWidth={2} opacity={0.45 * redP} />
              <rect x={miniX(c) - 32} y={miniY(r) - 20} width={64} height={40} rx={8} fill={ROLE.diverged} fillOpacity={0.55} stroke={ROLE.diverged} strokeWidth={3} opacity={redP} />
            </>
          )}
        </g>,
      );
    }
  }
  return <Svg opacity={o}>{cells}</Svg>;
};

/** The red ordering, lifted out of its cell, then shrunk: each operation steps out in turn; the red
 *  vanishes without the needed ones, so they snap back; `removeSku` stays out and the row closes up. */
const ShrinkRow: React.FC<{ liftAt: number; tries: number[]; collapseAt: number }> = ({ liftAt, tries, collapseAt }) => {
  const { frame, fps } = useScene();
  if (frame < liftAt) return null;
  const s = (sec: number) => Math.round(sec * fps);
  const lp = prog(frame, liftAt, 0.9, fps);
  const dx = mix(miniX(RED_CELL.c) - 960, 0, lp);
  const dy = mix(miniY(RED_CELL.r) - ROW_Y, 0, lp);
  const sc = mix(0.15, 1, lp);
  const full = centred(SHRINK_OPS, SZ, 960);
  const keptLefts = centred(
    SHRINK_OPS.filter((_, i) => i !== DROPPED),
    SZ,
    960,
  );
  const cp = frame < collapseAt ? 0 : prog(frame, collapseAt, 0.6, fps);
  let vanish = 0;
  tries.forEach((t, i) => {
    if (i === DROPPED || frame < t) return;
    vanish = Math.max(vanish, prog(frame, t + s(0.12), 0.15, fps) - prog(frame, t + s(0.45), 0.15, fps));
  });
  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        top: 0,
        width: 1920,
        height: 1080,
        transformOrigin: `960px ${ROW_Y}px`,
        transform: `translate(${dx}px, ${dy}px) scale(${sc})`,
        opacity: Math.min(1, lp * 2),
      }}
    >
      {SHRINK_OPS.map((op, i) => {
        const left = i === DROPPED ? full[i] : mix(full[i], keptLefts[i < DROPPED ? i : i - 1], cp);
        const t = tries[i];
        const outP = frame < t ? 0 : i === DROPPED ? prog(frame, t, 0.3, fps) : prog(frame, t, 0.25, fps) - prog(frame, t + s(0.42), 0.25, fps);
        const gone = i === DROPPED ? 1 - (frame < collapseAt - s(0.1) ? 0 : prog(frame, collapseAt - s(0.1), 0.35, fps)) : 1;
        const o = (1 - 0.82 * outP) * gone;
        const lift = -30 * outP;
        const arrowO = i === DROPPED ? o : 1;
        return (
          <React.Fragment key={i}>
            {i > 0 && arrowO > 0 && (
              <div
                style={{
                  position: "absolute",
                  left: left - SZ * 0.45 - SZ * MONO_ADVANCE,
                  top: ROW_Y,
                  transform: "translateY(-50%)",
                  fontFamily: FONT.mono,
                  fontSize: SZ,
                  color: C.dim,
                  opacity: arrowO,
                }}
              >
                →
              </div>
            )}
            {o > 0 && (
              <>
                <div style={{ opacity: o * (1 - vanish) }}>
                  <Ordering x={left} y={ROW_Y + lift} ops={[op]} size={SZ} color={ROLE.diverged} />
                </div>
                <div style={{ opacity: o * vanish }}>
                  <Ordering x={left} y={ROW_Y + lift} ops={[op]} size={SZ} color={C.dim} />
                </div>
              </>
            )}
          </React.Fragment>
        );
      })}
    </div>
  );
};

// ── the scene ─────────────────────────────────────────────────────────────────────────────────────

const VARY = ['cartSpec("derived.equivalent").vary {', "    Ordering(max: 4)", "    Budget(runs: 160)", "}"];

export const Explore: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const first = cue("First");
  const original = cue("the original");
  const runsOnce = cue("runs once");
  const whichValues = cue("which values");
  const then = cue("Then it builds");
  const orderings = cue("orderings");
  const variants = cue("seam variants");
  const fresh = cue("fresh sets");
  const everyPair = cue("Every pair");
  const bothCarts = cue("both carts");
  const identical = cue("identical inputs");
  const enormous = cue("enormous");
  const derived = cue("derived spec");
  const twelve = cue("twelve hundred runs");
  const fifty = cue("fifty orderings");
  const everything = cue("buy everything");
  const axes = cue("both axes");
  const together = cue("shrink together");
  const different = cue("different bugs");
  const bugs = cue("bugs");
  const edge = cue("Edge values");
  const small = cue("small budget");
  const middles = cue("random middles");
  const notEnds = cue("not ends");
  const vary = cue("Vary changes");
  const changes = cue("changes any");
  const anyOf = cue("any of it");
  const andWhen = cue("And when");
  const red = cue("goes red");
  const shrinks = cue("shrinks it");
  const dropping = cue("dropping operations");
  const ownVideo = cue("its own video");

  // Phase boundaries: each idea clears before the next arrives.
  const p2Out = different;
  const p3In = bugs + s(0.1);
  const p3Out = vary - s(0.25);
  const p5In = andWhen + s(0.4);

  const lift = track(frame, fps, [[0, 300], [then, 0]], 0.8);
  const zoom = track(frame, fps, [[0, 1], [enormous, ZOOM]], 1.4);
  const k = track(frame, fps, [[0, 1], [together, K]], 1.2);

  // Phase 2 geometry: the pulled-back patch, its shrinking budget rectangle, and the field's holes.
  const P = patch(ZOOM);
  const ix1 = P[0] + (P[2] - P[0]) * k;
  const iy1 = P[1] + (P[3] - P[1]) * k;
  const live = patch(zoom);
  const holes: Rect[] = [[live[0] - 190, live[1] - 90, live[2] + 24, live[3] + 64]];
  if (frame >= derived) holes.push([490, 180, 1430, 282]);
  if (frame >= together) holes.push([640, 772, 1280, 832]);
  holes.push([780, 936, 1140, 990]);
  const fieldO = (frame < enormous ? 0 : prog(frame, enormous, 1.2, fps)) * visibility(frame, fps, undefined, p2Out);
  const p2 = (t: number, dur = 0.45) => (frame < t ? 0 : prog(frame, t, dur, fps)) * visibility(frame, fps, undefined, p2Out);
  const shrinkO = p2(together, 0.4);

  const tries = SHRINK_OPS.map((_, i) => dropping + s(i * 0.55));
  const collapseAt = tries[tries.length - 1] + s(0.65);

  return (
    <>
      {/* 1 · the original runs once and the reads drop onto a tape */}
      <RunOnce first={first} original={original} runAt={runsOnce + s(0.25)} tapeAt={runsOnce} labelAt={whichValues} lift={lift} out={everyPair} />

      {/* 2 · orderings × seam variants, every pair on both carts; then the camera pulls back */}
      <Field zoom={zoom} opacity={fieldO} holes={holes} />
      <Grid orderings={orderings} variants={variants} fresh={fresh} bothCarts={bothCarts} identical={identical} enormous={enormous} zoom={zoom} out={p2Out} />
      <Label x={960} y={962} text="the declared space" size={30} opacity={p2(enormous + s(0.8), 0.6)} />
      <BudgetBox at={derived} runsAt={twelve} ordersAt={fifty} out={p2Out} />
      <Svg>
        <Box x={(P[0] + P[2]) / 2} y={(P[1] + P[3]) / 2} w={P[2] - P[0]} h={P[3] - P[1]} r={12} at={everything} out={p2Out} color={C.dim} dashed width={2.5} />
        <path
          d={`M ${P[0]} ${P[1]} H ${P[2]} V ${P[3]} H ${P[0]} Z M ${P[0]} ${P[1]} H ${ix1} V ${iy1} H ${P[0]} Z`}
          fill={C.bg}
          fillOpacity={0.72}
          fillRule="evenodd"
          opacity={shrinkO}
        />
        <rect x={P[0]} y={P[1]} width={ix1 - P[0]} height={iy1 - P[1]} rx={10} fill="none" stroke={C.text} strokeWidth={3} opacity={shrinkO} />
        <Arrow from={[P[0], 404]} to={[ix1, 404]} at={axes} out={p2Out} dur={0.5} color={C.dim} width={3} />
        <Arrow from={[574, P[1]]} to={[574, iy1]} at={axes + s(0.15)} out={p2Out} dur={0.5} color={C.dim} width={3} />
      </Svg>
      <Label x={(P[0] + ix1) / 2} y={372} text="seam variants" opacity={p2(axes)} />
      <Label x={552} y={(P[1] + iy1) / 2} text="orderings" align="right" opacity={p2(axes + s(0.15))} />
      <Label x={P[2]} y={P[3] + 32} text="full" size={26} align="right" opacity={p2(everything)} />
      <Text x={960} y={802} size={36} at={together + s(0.2)} out={p2Out} dur={0.8}>
        both axes × √(budget ÷ full)
      </Text>

      {/* 3 · edge values go first; a small budget drops the random middles */}
      <EdgeStrip at={p3In} reorder={edge + s(0.3)} small={small} middles={middles} notEnds={notEnds} out={p3Out} />

      {/* 4 · Vary changes any of it */}
      <CodeCard
        x={960}
        y={520}
        w={980}
        file="Tests/SpecTests/DerivedOpsTests.swift"
        lines={VARY}
        color={C.text}
        size={32}
        at={vary}
        out={andWhen}
        marks={[
          { line: 1, at: changes },
          { line: 2, at: anyOf },
        ]}
      />

      {/* 5 · a red run, lifted out and shrunk */}
      <MiniGrid at={p5In} redAt={red + s(0.1)} out={shrinks} />
      <ShrinkRow liftAt={red + s(0.4)} tries={tries} collapseAt={collapseAt} />
      <Label x={960} y={620} text="illustrative" size={26} opacity={frame < red + s(1.1) ? 0 : prog(frame, red + s(1.1), 0.5, fps)} />

      {/* 6 · the verdict is its own video */}
      <Verdict x={800} y={750} kind="diverged" at={ownVideo} />
      <Chip x={1135} y={750} lines={["→ verdicts video"]} color={C.dim} dashed opacity={frame < ownVideo + s(0.3) ? 0 : prog(frame, ownVideo + s(0.3), 0.45, fps)} />
    </>
  );
};
