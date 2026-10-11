import React from "react";
import { useScene, Svg, Arrow, Text, C, FONT, LINE_HEIGHT, MONO_ADVANCE, mix, prog, track, visibility } from "#kit";
import { Ordering, ROLE } from "./shared";

// The report card is report() over Tests/SpecTests/Fixtures/diverged.result.json, as scene 3 ends on it,
// quoted line for line. The code card quotes Tests/SpecTests/SpecPrototypeTests.swift, one line from each
// cart. The grid's counts are the fixture's (385 runs, 36 failing); their arrangement is illustrative. The
// live-campaign-check row is illustrative: generic operations, no real shrink. The fixture is a replay, so
// its order is the recorded one.

const REPORT = [
  "❌ DIVERGED  promo-cart.artifact → promo-cart.artifact",
  "  explored: 385 runs · all 7 orderings × 55 seam variants",
  "  stability: 3/3 identical replays",
  "  coverage: 100% of 4 declared boundaries · domain-swept 0%",
  "  covered: PromoCart — 3 ops · 385 probes",
  "  declared in: PromoCart ← RoundBugCart (HaruspecSpecTests/SpecPrototypeTests.swift)",
  "  seams: coffeeQty (2 positions) · boundary edges 8 of 8 scheduled · 47 combined (every seam at once)",
  "  blind spots: not audited — capture completeness is unmeasured; effect channels outside the recorded seams may exist",
  "  2 divergence(s):",
  "    ≠ CheckoutCompleted: total: baseline=1798 candidate=1799",
  "    ≠ PromoCart.checkout: value: baseline=1798 candidate=1799",
  "  ↳ failing order: addCoffee → addCoffee → promo → promo → checkout",
  "  ↳ counterexample: coffeeQty=1,1",
];

/** The report card: full width as scene 3 leaves it, narrowing left when the grid needs the room. */
const RC = { x: 80, top: 230, wide: 1760, narrow: 960, size: 22, header: 46, pad: 14, inset: 24, border: 2 };
const LH = RC.size * LINE_HEIGHT;
const CH = RC.size * MONO_ADVANCE;
const TEXT_LEFT = RC.x + RC.border + RC.inset;
const RC_H = RC.border * 2 + RC.header + RC.pad * 2 + REPORT.length * LH;
const lineY = (i: number) => RC.top + RC.border + RC.header + RC.pad + (i + 0.5) * LH;

/** The column where the `nth` occurrence of `needle` starts in report line `line`. */
function col(line: number, needle: string, nth = 0) {
  let c = -1;
  for (let k = 0; k <= nth; k++) c = REPORT[line].indexOf(needle, c + 1);
  return c;
}

/** The two cart lines, one from each, as the test file spells them. */
const CODE = [
  { text: "let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0", tag: "GoodCart (baseline)", color: ROLE.baseline },
  { text: "let discount = promo ? subtotal / 10 : 0 // BUG: truncates instead of rounding 10%", tag: "RoundBugCart (candidate)", color: ROLE.candidate },
];
const CODE_CARD = { x: 80, top: 784, w: 1760, size: 24, header: 50, row: 46 };

/** Chip rows, laid out exactly as the shared `Ordering` lays them out. */
const CHIP = 26;
function chipLayout(ops: string[], size = CHIP) {
  const step = size * 0.45 * 2 + size * MONO_ADVANCE;
  const widths = ops.map((op) => op.length * size * MONO_ADVANCE + size + 4);
  let cur = 0;
  const centers = widths.map((w, i) => {
    if (i > 0) cur += step;
    const c = cur + w / 2;
    cur += w;
    return c;
  });
  return { centers, widths, width: cur };
}

const ORDER = ["addCoffee", "addCoffee", "promo", "promo", "checkout"];
const ORDER_NTH = [0, 1, 0, 1, 0];
const ORDER_Y = 182;
const ORDER_ROW = chipLayout(ORDER);

/** 385 runs as squares, 20 to a row; the chosen red sits level with line 10. */
const GRID = { cols: 20, pitch: 28, cell: 22, x: 1162, y: 213, count: 385 };
const CHOSEN = 14 * GRID.cols + 1;
const RED = (() => {
  const set = new Set<number>([CHOSEN]);
  let x = 20261011;
  while (set.size < 36) {
    x = (x * 16807) % 2147483647;
    set.add(x % GRID.count);
  }
  return [...set].sort((a, b) => a - b);
})();
const cellCentre = (i: number) => ({
  x: GRID.x + (i % GRID.cols) * GRID.pitch + GRID.cell / 2,
  y: GRID.y + Math.floor(i / GRID.cols) * GRID.pitch + GRID.cell / 2,
});
const GRID_CX = GRID.x + ((GRID.cols - 1) * GRID.pitch + GRID.cell) / 2;
const GRID_BOTTOM = GRID.y + (Math.ceil(GRID.count / GRID.cols) - 1) * GRID.pitch + GRID.cell;

/** The illustrative live check: generic operations, three dropped while the divergence holds. */
const LIVE_OPS = ["op 1", "op 2", "op 3", "op 4", "op 5"];
const LIVE_ROW = chipLayout(LIVE_OPS);
const LIVE = { cx: 1440, y: 534 };
const LIVE_LEFT = LIVE.cx - LIVE_ROW.width / 2;

/** `a` blended toward `b` (both `#RRGGBB`). */
function mixHex(a: string, b: string, t: number) {
  const k = Math.max(0, Math.min(1, t));
  const ch = (h: string, i: number) => parseInt(h.slice(1 + i * 2, 3 + i * 2), 16);
  return `#${[0, 1, 2].map((i) => Math.round(mix(ch(a, i), ch(b, i), k)).toString(16).padStart(2, "0")).join("")}`;
}
/** An opacity as a two-digit hex alpha suffix. */
const alpha = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0");

const underline = (color: string, p: number): React.CSSProperties => ({
  backgroundImage: `linear-gradient(${color}, ${color})`,
  backgroundRepeat: "no-repeat",
  backgroundPosition: "0 100%",
  backgroundSize: `${p * 100}% 3px`,
  paddingBottom: 3,
});

export const Diverged: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);
  const P = (at: number, dur: number) => (frame < at ? 0 : prog(frame, at, dur, fps));

  const below = cue("Below the block");
  const aRed = cue("a red says");
  const twoDiv = cue("Two divergences");
  const total = cue("checkout event's total");
  const retVal = cue("checkout's return value");
  const cent = cue("one cent higher");
  const truncates = cue("truncates");
  const discount = cue("a discount");
  const rounded = cue("rounded");
  const failingOrder = cue("the failing order");
  const lifts = [cue("two adds"), cue("adds"), cue("two promos"), cue("promos"), cue("checkout", { after: cue("then checkout") })];
  const counter = cue("counterexample");
  const seamValues = cue("the seam values");
  const one = cue("one", { after: cue("quantity") });
  const twice = cue("twice");
  const keeps = cue("keeps every failing case");
  const failingCase = cue("failing case");
  const informative = cue("the most informative one");
  const liveCheck = cue("On a live campaign check");
  const live = cue("live campaign check");
  const drops = [
    { i: 1, at: cue("shrinks the order") },
    { i: 3, at: cue("dropping") },
    { i: 2, at: cue("while the divergence holds") },
  ];
  const replayA = cue("A replay");
  const replay = cue("replay", { after: replayA });
  const recorded = cue("the order it recorded");

  // ── The report card ─────────────────────────────────────────────────────────────────────────────
  const dimBlock = P(below, 0.8);
  const brightRed = P(aRed, 0.8);
  const bright = (i: number) => (i === 0 ? 1 : i <= 7 ? 1 - dimBlock : brightRed);

  const HL: Record<number, [number, number | undefined][]> = {
    8: [[twoDiv, total]],
    9: [[total, failingOrder], [informative, liveCheck]],
    10: [[retVal, failingOrder]],
    11: [[failingOrder, counter], [replay, undefined]],
    12: [[counter, keeps]],
  };
  const hl = (i: number) =>
    Math.min(1, (HL[i] ?? []).reduce((acc, [on, off]) => acc + P(on, 0.4) * visibility(frame, fps, undefined, off, 0.4), 0));

  const width = track(frame, fps, [[0, RC.wide], [keeps, RC.narrow]], 0.8);
  const narrowed = P(keeps, 0.8);

  const digit = (at: number, base: string): React.CSSProperties => {
    const c = P(at, 0.3);
    const bump = c * (1 - P(at + s(0.4), 0.6));
    return { color: mixHex(base, ROLE.seam, c), textShadow: bump > 0 ? `0 0 ${16 * bump}px ${ROLE.seam}` : "none" };
  };

  const content = (i: number, base: string): React.ReactNode => {
    const ln = REPORT[i];
    if (i === 0) {
      const k = ln.indexOf("DIVERGED");
      return (
        <>
          {ln.slice(0, k)}
          <span style={{ color: ROLE.diverged, fontWeight: 600 }}>DIVERGED</span>
          {ln.slice(k + 8)}
        </>
      );
    }
    if (i === 9 || i === 10) {
      const p = P(i === 9 ? total : retVal, 0.5);
      const a = ln.indexOf("1798");
      const b = ln.indexOf("1799");
      return (
        <>
          {ln.slice(0, a)}
          <span style={{ color: mixHex(base, ROLE.baseline, p) }}>1798</span>
          {ln.slice(a + 4, b)}
          <span style={{ color: mixHex(base, ROLE.candidate, p) }}>1799</span>
          {ln.slice(b + 4)}
        </>
      );
    }
    if (i === 12) {
      const k = ln.indexOf("coffeeQty");
      return (
        <>
          {ln.slice(0, k)}
          <span style={underline(ROLE.seam, P(counter + s(0.3), 0.5))}>
            <span style={{ color: mixHex(base, ROLE.seam, P(seamValues, 0.5)) }}>coffeeQty</span>=<span style={digit(one, base)}>1</span>,<span style={digit(twice, base)}>1</span>
          </span>
        </>
      );
    }
    return ln;
  };

  const card = (
    <div
      style={{
        position: "absolute",
        left: RC.x,
        top: RC.top,
        width,
        height: RC_H,
        boxSizing: "border-box",
        border: `${RC.border}px solid ${C.faint}`,
        borderRadius: 14,
        background: C.surface,
        overflow: "hidden",
      }}
    >
      <div
        style={{
          height: RC.header,
          boxSizing: "border-box",
          borderBottom: `2px solid ${C.faint}`,
          display: "flex",
          alignItems: "center",
          padding: `0 ${RC.inset}px`,
          fontFamily: FONT.mono,
          fontSize: RC.size,
          color: C.dim,
          whiteSpace: "nowrap",
        }}
      >
        Tests/SpecTests/Fixtures/diverged.result.json · report()
      </div>
      <div style={{ padding: `${RC.pad}px ${RC.inset}px` }}>
        {REPORT.map((_, i) => {
          const b = bright(i);
          const base = mixHex(C.dim, C.text, b);
          const h = hl(i);
          return (
            <div
              key={i}
              style={{
                height: LH,
                lineHeight: `${LH}px`,
                margin: "0 -12px",
                padding: "0 12px",
                whiteSpace: "pre",
                fontFamily: FONT.mono,
                fontSize: RC.size,
                color: base,
                opacity: mix(0.6, 1, b),
                borderRadius: 4,
                background: h > 0 ? `${ROLE.diverged}${alpha(0.16 * h)}` : undefined,
                boxShadow: h > 0 ? `inset 4px 0 0 ${ROLE.diverged}${alpha(h)}` : undefined,
              }}
            >
              {content(i, base)}
            </div>
          );
        })}
      </div>
      {/* The qualification lines run off the narrowed card: fade their tails. */}
      {narrowed > 0 && (
        <div
          style={{
            position: "absolute",
            right: 0,
            top: RC.header + RC.pad + LH,
            width: 180,
            height: 7 * LH,
            background: `linear-gradient(to right, ${C.surface}00, ${C.surface} 70%)`,
            opacity: narrowed,
          }}
        />
      )}
    </div>
  );

  // "+1¢": one bracket pinned to both divergence lines, just past their "1799".
  const centP = P(cent, 0.5);
  const bx = TEXT_LEFT + 62 * CH;
  const y9 = lineY(9);
  const y10 = lineY(10);
  const centTag = centP > 0 && (
    <>
      <Svg opacity={centP}>
        <path
          d={`M ${bx} ${y9 - 12} L ${bx + 8} ${y9 - 12} L ${bx + 8} ${y10 + 12} L ${bx} ${y10 + 12} M ${bx + 8} ${(y9 + y10) / 2} L ${bx + 16} ${(y9 + y10) / 2}`}
          fill="none"
          stroke={ROLE.candidate}
          strokeWidth={3}
          strokeLinejoin="round"
        />
      </Svg>
      <div
        style={{
          position: "absolute",
          left: bx + 22,
          top: (y9 + y10) / 2,
          transform: `translate(0, -50%) scale(${mix(0.7, 1, centP)})`,
          transformOrigin: "left center",
          fontFamily: FONT.mono,
          fontSize: 26,
          lineHeight: "32px",
          color: ROLE.candidate,
          border: `2px solid ${ROLE.candidate}`,
          background: `${ROLE.candidate}1E`,
          borderRadius: 999,
          padding: "0 10px",
          whiteSpace: "nowrap",
          opacity: centP,
        }}
      >
        +1¢
      </div>
    </>
  );

  // ── The code card: one line from each cart ──────────────────────────────────────────────────────
  const codeIn = P(truncates, 0.6);
  const codeO = codeIn * visibility(frame, fps, undefined, failingOrder, 0.45);
  const codeLine = (k: number) => {
    const t = CODE[k].text;
    if (k === 0) {
      const a = t.indexOf(".rounded()");
      return (
        <>
          {t.slice(0, a)}
          <span style={underline(ROLE.baseline, P(rounded, 0.5))}>.rounded()</span>
          {t.slice(a + 10)}
        </>
      );
    }
    const a = t.indexOf("subtotal / 10");
    const c = t.indexOf("// BUG");
    return (
      <>
        {t.slice(0, a)}
        <span style={underline(ROLE.candidate, P(discount, 0.5))}>subtotal / 10</span>
        {t.slice(a + 13, c)}
        <span style={{ color: C.dim }}>{t.slice(c)}</span>
      </>
    );
  };
  const codeCard = codeO > 0 && (
    <div
      style={{
        position: "absolute",
        left: CODE_CARD.x,
        top: CODE_CARD.top,
        width: CODE_CARD.w,
        boxSizing: "border-box",
        border: `2px solid ${C.faint}`,
        borderRadius: 14,
        background: C.surface,
        opacity: codeO,
        transform: `translateX(${(1 - codeIn) * 180}px)`,
        overflow: "hidden",
      }}
    >
      <div style={{ height: CODE_CARD.header, boxSizing: "border-box", borderBottom: `2px solid ${C.faint}`, display: "flex", alignItems: "center", padding: "0 24px", fontFamily: FONT.mono, fontSize: 26, color: C.dim }}>
        Tests/SpecTests/SpecPrototypeTests.swift
      </div>
      <div style={{ padding: "10px 20px", display: "flex", flexDirection: "column", gap: 6 }}>
        {CODE.map((c, k) => (
          <div
            key={k}
            style={{
              height: CODE_CARD.row,
              display: "flex",
              alignItems: "center",
              borderLeft: `5px solid ${c.color}`,
              background: `${c.color}14`,
              borderRadius: "0 8px 8px 0",
              padding: "0 12px 0 18px",
            }}
          >
            <span style={{ fontFamily: FONT.mono, fontSize: CODE_CARD.size, color: C.text, whiteSpace: "pre" }}>{codeLine(k)}</span>
            <span style={{ flex: 1 }} />
            <span
              style={{
                fontFamily: FONT.mono,
                fontSize: 26,
                lineHeight: "34px",
                color: c.color,
                border: `2px solid ${c.color}`,
                background: `${c.color}1E`,
                borderRadius: 999,
                padding: "0 14px",
                whiteSpace: "nowrap",
              }}
            >
              {c.tag}
            </span>
          </div>
        ))}
      </div>
    </div>
  );

  // ── The failing order: line 12's labels lift into chips above the card ──────────────────────────
  const ghosts = ORDER.map((op, i) => {
    const t = lifts[i];
    if (frame < t) return null;
    const p = P(t, 0.5);
    const o = 1 - P(t + s(0.4), 0.3);
    if (o <= 0) return null;
    const from = { x: TEXT_LEFT + (col(11, op, ORDER_NTH[i]) + op.length / 2) * CH, y: lineY(11) };
    const to = { x: RC.x + ORDER_ROW.centers[i], y: ORDER_Y };
    return (
      <div
        key={i}
        style={{
          position: "absolute",
          left: mix(from.x, to.x, p),
          top: mix(from.y, to.y, p),
          transform: "translate(-50%, -50%)",
          fontFamily: FONT.mono,
          fontSize: mix(RC.size, CHIP, p),
          color: C.text,
          whiteSpace: "nowrap",
          opacity: o,
          textShadow: `0 0 10px ${C.bg}`,
        }}
      >
        {op}
      </div>
    );
  });

  // ── Every failing case kept; the most informative one reported ──────────────────────────────────
  const gridO = visibility(frame, fps, undefined, liveCheck, 0.5);
  const focus = P(informative, 0.5);
  const chosen = cellCentre(CHOSEN);
  const grid =
    frame >= keeps && gridO > 0 ? (
      <Svg opacity={gridO}>
        {Array.from({ length: GRID.count }, (_, i) => {
          if (i === CHOSEN) return null;
          const shown = P(keeps + s(0.3) + Math.round((i / GRID.count) * s(0.9)), 0.25);
          if (shown <= 0) return null;
          const k = RED.indexOf(i);
          const red = k < 0 ? 0 : P(failingCase + Math.round((k / RED.length) * s(0.7)), 0.3);
          const { x, y } = cellCentre(i);
          return (
            <rect
              key={i}
              x={x - GRID.cell / 2}
              y={y - GRID.cell / 2}
              width={GRID.cell}
              height={GRID.cell}
              rx={4}
              fill={mixHex(C.faint, ROLE.diverged, red)}
              opacity={shown * (red > 0 ? mix(1, 0.5, focus) : mix(1, 0.7, focus))}
            />
          );
        })}
        {(() => {
          const shown = P(keeps + s(0.3) + Math.round((CHOSEN / GRID.count) * s(0.9)), 0.25);
          const red = P(failingCase + Math.round((RED.indexOf(CHOSEN) / RED.length) * s(0.7)), 0.3);
          const half = (GRID.cell / 2) * mix(1, 2.4, focus);
          return (
            <rect
              x={chosen.x - half}
              y={chosen.y - half}
              width={half * 2}
              height={half * 2}
              rx={mix(4, 8, focus)}
              fill={mixHex(C.faint, ROLE.diverged, red)}
              stroke={C.text}
              strokeWidth={3 * focus}
              opacity={shown}
              style={{ filter: focus > 0 ? `drop-shadow(0 0 ${14 * focus}px ${ROLE.diverged})` : undefined }}
            />
          );
        })()}
      </Svg>
    ) : null;
  const gridCaption = frame >= keeps && gridO > 0 && (
    <div
      style={{
        position: "absolute",
        left: GRID_CX,
        top: GRID_BOTTOM + 40,
        transform: "translate(-50%, -50%)",
        fontFamily: FONT.mono,
        fontSize: 26,
        color: C.dim,
        whiteSpace: "pre",
        opacity: gridO * P(keeps + s(0.6), 0.5),
      }}
    >
      385 runs<span style={{ color: ROLE.diverged, opacity: P(failingCase + s(0.4), 0.5) }}> · 36 failing</span>
    </div>
  );

  // ── Illustrative: a live check shrinks the order ────────────────────────────────────────────────
  const liveO = track(frame, fps, [[0, 1], [replayA, 0.3]], 0.6);
  const firstTick = drops[0].at + s(0.45);
  const liveRow =
    frame >= live ? (
      <div style={{ opacity: liveO }}>
        {LIVE_OPS.map((op, i) => {
          const p = P(live + s(0.3 + i * 0.1), 0.4);
          const drop = drops.find((d) => d.i === i);
          const g = drop ? P(drop.at, 0.4) : 0;
          const color = mixHex(C.text, C.dim, g);
          const cx = LIVE_LEFT + LIVE_ROW.centers[i];
          const prevRight = i > 0 ? LIVE_LEFT + LIVE_ROW.centers[i - 1] + LIVE_ROW.widths[i - 1] / 2 : 0;
          const arrowX = i > 0 ? (prevRight + cx - LIVE_ROW.widths[i] / 2) / 2 : 0;
          return (
            <React.Fragment key={i}>
              {i > 0 && (
                <div style={{ position: "absolute", left: arrowX, top: LIVE.y, transform: "translate(-50%, -50%)", fontFamily: FONT.mono, fontSize: CHIP, color: C.dim, opacity: p }}>→</div>
              )}
              <div
                style={{
                  position: "absolute",
                  left: cx,
                  top: LIVE.y,
                  transform: `translate(-50%, calc(-50% + ${(1 - p) * 10}px))`,
                  fontFamily: FONT.mono,
                  fontSize: CHIP,
                  color,
                  border: `2px solid ${color}88`,
                  borderRadius: 999,
                  padding: `2px ${CHIP * 0.5}px`,
                  whiteSpace: "nowrap",
                  textDecoration: g > 0.5 ? "line-through" : "none",
                  opacity: p * mix(1, 0.7, g),
                }}
              >
                {op}
              </div>
            </React.Fragment>
          );
        })}
        <Svg>
          {drops.map(({ i, at }) => {
            const t = P(at + s(0.45), 0.35);
            if (t <= 0) return null;
            const x = LIVE_LEFT + LIVE_ROW.centers[i];
            const y = LIVE.y + 46;
            return (
              <path
                key={i}
                d={`M ${x - 10} ${y} L ${x - 3} ${y + 8} L ${x + 11} ${y - 9}`}
                pathLength={1}
                strokeDasharray={1}
                strokeDashoffset={1 - t}
                fill="none"
                stroke={ROLE.diverged}
                strokeWidth={4}
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            );
          })}
        </Svg>
        <div
          style={{
            position: "absolute",
            left: LIVE.cx,
            top: LIVE.y + 104,
            transform: "translate(-50%, -50%)",
            display: "flex",
            alignItems: "center",
            gap: 12,
            fontFamily: FONT.serif,
            fontStyle: "italic",
            fontSize: 28,
            color: ROLE.diverged,
            whiteSpace: "nowrap",
            opacity: P(firstTick, 0.5),
          }}
        >
          <svg width={26} height={24} viewBox="0 0 26 24">
            <path d="M 3 12 L 10 20 L 23 4" fill="none" stroke={ROLE.diverged} strokeWidth={4} strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          still diverges
        </div>
      </div>
    ) : null;

  return (
    <>
      {card}
      {centTag}
      {codeCard}

      <Ordering x={RC.x} y={ORDER_Y} ops={ORDER} ats={lifts.map((t) => t + s(0.35))} out={keeps} />
      {ghosts}

      {grid}
      <Svg>
        <Arrow from={[chosen.x - GRID.cell * 1.2 - 10, chosen.y]} to={[RC.x + RC.narrow + 10, lineY(9)]} at={informative + s(0.3)} out={liveCheck} dur={0.5} color={ROLE.diverged} width={3} />
      </Svg>
      {gridCaption}

      <div style={{ opacity: liveO }}>
        <Text x={LIVE.cx} y={414} size={32} italic color={C.text} at={live} reveal="write">
          live campaign check
        </Text>
        <Text x={LIVE.cx} y={456} size={26} italic color={C.dim} at={live + s(0.4)} reveal="fade">
          illustrative
        </Text>
      </div>
      {liveRow}

      {/* The replay's row returns: the order as recorded, unshrunk. */}
      <Ordering x={RC.x} y={ORDER_Y} ops={ORDER} ats={ORDER.map((_, i) => recorded + s(i * 0.1))} />
      <Text x={RC.x + ORDER_ROW.width + 36} y={ORDER_Y} size={28} italic color={C.text} anchor="left" at={recorded + s(0.5)} reveal="fade">
        replay: as recorded
      </Text>
    </>
  );
};
