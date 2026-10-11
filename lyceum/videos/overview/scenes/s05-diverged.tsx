import React from "react";
import { useScene, Fade, Line, Svg, C, FONT, MONO_ADVANCE, mix, prog, track } from "#kit";
import { ROLE, VERDICT, useAppear } from "./shared";

// Real lines: the two discount lines are from Tests/SpecTests/SpecPrototypeTests.swift; the report is
// the README's At a glance output (a live `verify(candidate:)` run), abridged: the stability, seams
// and failing-order lines are left out.

const LEGACY = "let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0";
const PORT = "let discount = promo ? subtotal / 10 : 0";

const REPORT = [
  "❌ DIVERGED  promo-cart → promo-cart",
  "  explored: 384 runs · all 6 orderings × 64 seam variants",
  "  coverage: 100% of 4 declared boundaries · domain-swept 0%",
  "  covered: PromoCart — 3 ops · 384 probes",
  "  blind spots: not audited — capture completeness is unmeasured;",
  "               effect channels outside the recorded seams may exist",
  "  2 divergence(s):",
  "    ≠ CheckoutCompleted: total: baseline=1798 candidate=1799",
  "    ≠ PromoCart.checkout: value: baseline=1798 candidate=1799",
  "  ↳ counterexample: coffeeQty=1,1",
];
const GHOST = `${VERDICT.equivalent.icon} ${VERDICT.equivalent.text}  promo-cart → promo-cart`;

// Top band: two code strips, label column on the left, the pair centred in the frame.
const CODE = 30;
const ADV = CODE * MONO_ADVANCE;
const STRIP_PAD = 26;
const STRIP_H = 72;
const STRIP_W = LEGACY.length * ADV + STRIP_PAD * 2;
const LABEL_W = 134;
const STRIP_X = (1920 - (STRIP_W + LABEL_W)) / 2 + LABEL_W;
const LEGACY_Y = 195;
const PORT_Y = 292;

// The slider: coffeeQty 1…20.
const SL = { x0: 640, x1: 1300, y: 700 };
const qtyX = (q: number) => mix(SL.x0, SL.x1, (q - 1) / 19);

// The report card: x 80…1840, mono 26.
const RS = 26;
const RADV = RS * MONO_ADVANCE;
const LH = 50;
const CARD = { x: 80, w: 1760, top: 236, padX: 60, padY: 44 };
const CARD_H = CARD.padY * 2 + REPORT.length * LH;
const TEXT_X = CARD.x + CARD.padX;
const rowTop = (i: number) => CARD.top + CARD.padY + i * LH;
const ROW_W = Math.max(...REPORT.map((l) => l.length)) * RADV + 28;
const BLOCK = [1, 2, 3, 4, 5];
const BLOCK_RIGHT = TEXT_X + Math.max(...BLOCK.map((i) => REPORT[i].length)) * RADV + 26;

/** `color` (`#RRGGBB`) with an alpha. */
const tint = (color: string, a: number) => color + Math.round(Math.max(0, Math.min(1, a)) * 255).toString(16).padStart(2, "0");

/** A colour `t` of the way from `a` to `b` (both `#RRGGBB`). */
function blend(a: string, b: string, t: number): string {
  const pa = parseInt(a.slice(1), 16);
  const pb = parseInt(b.slice(1), 16);
  const ch = (shift: number) => Math.round(mix((pa >> shift) & 255, (pb >> shift) & 255, t));
  return `rgb(${ch(16)}, ${ch(8)}, ${ch(0)})`;
}

/** On from `on`, off from `off`: smoothed 0 → 1 → 0. */
function windowed(frame: number, fps: number, on: number, off?: number, dur = 0.4): number {
  const up = prog(frame, on, dur, fps);
  return off === undefined ? up : up * (1 - prog(frame, off, dur, fps));
}

/** One line of code in a role-coloured strip, labelled at the left. It fades in, or writes on, from
 *  `at`; `marks` underline column ranges, each drawing on from its own frame. */
const Strip: React.FC<{
  y: number;
  code: string;
  label: string;
  color: string;
  at: number;
  write?: boolean;
  marks?: { from: number; to: number; at: number; color: string }[];
}> = ({ y, code, label, color, at, write = false, marks = [] }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.5);
  if (o <= 0) return null;
  const typed = write ? prog(frame, at + Math.round(0.15 * fps), 0.8, fps) : 1;
  const codeX = STRIP_X + STRIP_PAD;
  return (
    <>
      <div
        style={{
          position: "absolute",
          left: STRIP_X - 24 - LABEL_W,
          top: y - STRIP_H / 2,
          width: LABEL_W,
          height: STRIP_H,
          lineHeight: `${STRIP_H}px`,
          textAlign: "right",
          fontFamily: FONT.serif,
          fontStyle: "italic",
          fontSize: 32,
          color,
          opacity: o,
        }}
      >
        {label}
      </div>
      <div
        style={{
          position: "absolute",
          left: STRIP_X,
          top: y - STRIP_H / 2,
          width: STRIP_W,
          height: STRIP_H,
          boxSizing: "border-box",
          borderRadius: 14,
          border: `3px solid ${color}`,
          background: `linear-gradient(180deg, ${color}1C, ${color}08)`,
          opacity: o,
          transform: `scale(${mix(0.97, 1, o)})`,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: codeX,
          top: y - STRIP_H / 2,
          height: STRIP_H,
          lineHeight: `${STRIP_H}px`,
          fontFamily: FONT.mono,
          fontSize: CODE,
          color: C.text,
          whiteSpace: "pre",
          opacity: o,
          clipPath: `inset(0 ${(1 - typed) * 100}% 0 0)`,
        }}
      >
        {code}
      </div>
      {marks.map((m, i) => {
        const p = prog(frame, m.at, 0.4, fps);
        if (p <= 0) return null;
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: codeX + m.from * ADV,
              top: y + 21,
              width: (m.to - m.from) * ADV * p,
              height: 4,
              borderRadius: 2,
              background: m.color,
            }}
          />
        );
      })}
    </>
  );
};

/** The coffeeQty slider: a 1…20 track whose ticks light as the knob visits them; the knob holds at
 *  `q(frame)`. */
const Slider: React.FC<{ at: number; q: (f: number) => number; sweepAt: number; runs: number }> = ({ at, q, sweepAt, runs }) => {
  const { frame } = useScene();
  const o = useAppear(at, undefined, 0.5);
  if (o <= 0) return null;
  let lo = 10;
  let hi = 10;
  for (let f = sweepAt; f <= frame; f++) {
    const v = q(f);
    lo = Math.min(lo, v);
    hi = Math.max(hi, v);
  }
  const now = q(frame);
  const knobX = qtyX(now);
  const mono = { fontFamily: FONT.mono, fontSize: 28, whiteSpace: "pre" as const };
  return (
    <div style={{ position: "absolute", inset: 0, opacity: o }}>
      <div style={{ ...mono, position: "absolute", left: SL.x0 - 48, top: SL.y, transform: "translate(-100%, -50%)", color: C.text }}>coffeeQty</div>
      <div style={{ position: "absolute", left: SL.x0, top: SL.y - 2, width: SL.x1 - SL.x0, height: 4, borderRadius: 2, background: C.faint }} />
      <div style={{ position: "absolute", left: qtyX(lo), top: SL.y - 2, width: qtyX(hi) - qtyX(lo), height: 4, borderRadius: 2, background: C.dim }} />
      {Array.from({ length: 20 }, (_, i) => {
        const n = i + 1;
        const visited = n >= Math.floor(lo + 0.5) && n <= Math.ceil(hi - 0.5);
        const color = n === 10 ? ROLE.equivalent : visited ? C.text : C.faint;
        return <div key={n} style={{ position: "absolute", left: qtyX(n) - 1.5, top: SL.y - 12, width: 3, height: 24, borderRadius: 1.5, background: color }} />;
      })}
      {[1, 10, 20].map((n) => (
        <div key={n} style={{ ...mono, fontSize: 26, position: "absolute", left: qtyX(n), top: SL.y + 44, transform: "translate(-50%, -50%)", color: n === 10 ? ROLE.equivalent : C.dim }}>
          {n}
        </div>
      ))}
      <div
        style={{
          position: "absolute",
          left: knobX - 16,
          top: SL.y - 16,
          width: 32,
          height: 32,
          borderRadius: 16,
          background: C.text,
          boxShadow: `0 0 0 4px ${C.bg}`,
        }}
      />
      <div style={{ ...mono, position: "absolute", left: knobX, top: SL.y - 52, transform: "translate(-50%, -50%)", color: C.text }}>{Math.round(now)}</div>
      {runs >= 0 && (
        <div style={{ ...mono, position: "absolute", left: SL.x1 + 56, top: SL.y, transform: "translate(0, -50%)", color: C.dim }}>
          <span style={{ color: C.text }}>{runs}</span> runs
        </div>
      )}
    </div>
  );
};

/** A report line, with every `1798` blending to the baseline colour and every `1799` to the candidate's
 *  as `numbers` goes 0 → 1. */
const ReportLine: React.FC<{ text: string; color: string; numbers: number; weight?: number }> = ({ text, color, numbers, weight = 400 }) => (
  <>
    {text.split(/(1798|1799)/).map((part, k) => {
      const role = part === "1798" ? ROLE.baseline : part === "1799" ? ROLE.candidate : undefined;
      if (!role) return <React.Fragment key={k}>{part}</React.Fragment>;
      return (
        <span key={k} style={{ color: blend(color, role, numbers), fontWeight: numbers > 0.5 ? 600 : weight }}>
          {part}
        </span>
      );
    })}
  </>
);

export const Diverged: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const truncates = cue("truncates the discount");
  const rounded = cue("rounded it");
  const tenCoffees = cue("At ten coffees");
  const agree = cue("agree to the cent");
  const pass = cue("would pass");
  const stopAtTen = cue("doesn't stop at ten");
  const across = cue("Across a few hundred runs");
  const diverged = cue("diverged");
  const oneCent = cue("one cent more");
  const notification = cue("total in the checkout notification");
  const returns = cue("value checkout returns");
  const quantity = cue("quantity of one");
  const beneath = cue("beneath it");
  const measured = cue("what the verdict was measured over");
  const explored = cue("how much was explored");
  const covered = cue("what was covered");
  const couldNot = cue("could not see");
  const every = cue("Every verdict carries that block");
  const green = cue("green or red");
  const red = cue("red", { after: green });

  // ── Top band ─────────────────────────────────────────────────────────────────────────────────
  const bandY = track(frame, fps, [[0, 0], [diverged, -420]], 0.6);
  const bandO = 1 - prog(frame, diverged, 0.45, fps);
  const atTenDim = mix(1, 0.45, prog(frame, stopAtTen, 0.5, fps));

  const roundedCol = LEGACY.indexOf(".rounded()");
  const slashCol = PORT.indexOf("/ 10");

  const sweepAt = stopAtTen + s(0.7);
  const leg = s(1.2);
  const qty = (f: number) =>
    track(f, fps, [[0, 10], [sweepAt, 1], [sweepAt + leg, 20], [sweepAt + 2 * leg, 1], [sweepAt + 3 * leg, 20]], 1.15);
  const runs = frame < across ? -1 : Math.round(384 * prog(frame, across, (diverged - across) / fps - 0.1, fps));

  const totalsIn = prog(frame, agree, 0.5, fps);
  const equalsIn = prog(frame, agree + s(0.35), 0.4, fps);
  const passGlow = windowed(frame, fps, pass, pass + s(0.9), 0.35);

  // ── Report card ──────────────────────────────────────────────────────────────────────────────
  const cardIn = diverged + s(0.15);
  const cardO = frame < cardIn ? 0 : prog(frame, cardIn, 0.5, fps);
  const lineAt = (i: number) => cardIn + s(0.3 + 0.13 * i);
  const numbers = prog(frame, oneCent, 0.5, fps);
  const ghost = windowed(frame, fps, green, red + s(0.2), 0.4);

  // Soft row highlights: red for what diverged and why, neutral for the qualification block.
  const all = windowed(frame, fps, every);
  const lights: Record<number, { a: number; color: string }> = {
    7: { a: windowed(frame, fps, notification, returns), color: ROLE.diverged },
    8: { a: windowed(frame, fps, returns, quantity), color: ROLE.diverged },
    9: { a: windowed(frame, fps, quantity, measured), color: ROLE.diverged },
    1: { a: Math.max(windowed(frame, fps, explored, covered), all), color: C.text },
    2: { a: Math.max(windowed(frame, fps, covered, couldNot), all), color: C.text },
    3: { a: Math.max(windowed(frame, fps, covered, couldNot), all), color: C.text },
    4: { a: windowed(frame, fps, couldNot), color: C.text },
    5: { a: windowed(frame, fps, couldNot), color: C.text },
  };
  // While the narration walks the block, the unlit block lines step back; the divergences step back
  // once the block is in play.
  const walking = windowed(frame, fps, explored, every);
  const divergencesBack = prog(frame, measured, 0.6, fps);
  const rowOpacity = (i: number) => {
    if (BLOCK.includes(i)) return mix(1, 0.45, walking * (1 - (lights[i]?.a ?? 0)));
    if (i >= 6) return mix(1, 0.4, divergencesBack);
    return 1;
  };

  // The qualification bracket: down the left of rows 1–5, closed on the right, labelled there.
  const bTop = rowTop(1) + 6;
  const bBottom = rowTop(6) - 6;
  const bLeft = TEXT_X - 26;
  const bWidth = mix(3, 5, all);
  const blockLabel = useAppear(measured + s(0.5), undefined, 0.5);
  const centLabel = useAppear(oneCent + s(0.3), beneath, 0.45);

  return (
    <>
      {/* The two discount lines, the ten-coffee check, and the sweep beyond it. */}
      {bandO > 0 && (
        <div style={{ position: "absolute", inset: 0, transform: `translateY(${bandY}px)`, opacity: bandO }}>
          <Strip
            y={LEGACY_Y}
            code={LEGACY}
            label="legacy"
            color={ROLE.baseline}
            at={0}
            marks={[{ from: roundedCol, to: roundedCol + ".rounded()".length, at: rounded, color: ROLE.baseline }]}
          />
          <Strip
            y={PORT_Y}
            code={PORT}
            label="port"
            color={ROLE.candidate}
            at={truncates}
            write
            marks={[{ from: slashCol, to: slashCol + 4, at: truncates + s(1.0), color: ROLE.diverged }]}
          />

          <div style={{ position: "absolute", inset: 0, opacity: atTenDim }}>
            <Fade x={960} y={440} anchor="center" at={tenCoffees} rise={12}>
              <div
                style={{
                  fontFamily: FONT.mono,
                  fontSize: 28,
                  color: C.text,
                  background: C.surface,
                  border: `2px solid ${C.faint}`,
                  borderRadius: 14,
                  padding: "10px 30px",
                  whiteSpace: "pre",
                }}
              >
                10 × 999 = 9990 → discount 999 <span style={{ color: C.dim }}>either way</span>
              </div>
            </Fade>
            {totalsIn > 0 && (
              <div
                style={{
                  position: "absolute",
                  left: 960,
                  top: 532,
                  transform: "translate(-50%, -50%)",
                  display: "flex",
                  alignItems: "center",
                  gap: 30,
                  fontFamily: FONT.mono,
                  whiteSpace: "nowrap",
                }}
              >
                <span style={{ fontSize: 34, color: ROLE.baseline, opacity: totalsIn }}>8991</span>
                <span
                  style={{
                    fontSize: 48,
                    fontWeight: 700,
                    color: ROLE.equivalent,
                    opacity: equalsIn,
                    display: "inline-block",
                    transform: `scale(${mix(0.6, 1, equalsIn) * (1 + 0.15 * passGlow)})`,
                    textShadow: passGlow > 0 ? `0 0 ${24 * passGlow}px ${ROLE.equivalent}` : "none",
                  }}
                >
                  =
                </span>
                <span style={{ fontSize: 34, color: ROLE.candidate, opacity: totalsIn }}>8991</span>
              </div>
            )}
          </div>

          <Slider at={stopAtTen} q={qty} sweepAt={sweepAt} runs={runs} />
        </div>
      )}

      {/* The report. */}
      {cardO > 0 && (
        <div style={{ position: "absolute", inset: 0, opacity: cardO, transform: `translateY(${(1 - cardO) * 40}px)` }}>
          <div
            style={{
              position: "absolute",
              left: CARD.x,
              top: CARD.top,
              width: CARD.w,
              height: CARD_H,
              boxSizing: "border-box",
              borderRadius: 16,
              border: `2px solid ${C.faint}`,
              background: C.surface,
            }}
          />
          <div
            style={{
              position: "absolute",
              right: 1920 - (CARD.x + CARD.w) + 30,
              top: CARD.top + 18,
              fontFamily: FONT.serif,
              fontStyle: "italic",
              fontSize: 26,
              color: C.dim,
            }}
          >
            abridged
          </div>

          {REPORT.map((_, i) => {
            const l = lights[i];
            if (!l || l.a <= 0) return null;
            return (
              <div
                key={`hl${i}`}
                style={{
                  position: "absolute",
                  left: TEXT_X - 12,
                  top: rowTop(i) + 3,
                  width: ROW_W,
                  height: LH - 6,
                  borderRadius: 8,
                  background: tint(l.color, (l.color === C.text ? 0.1 : 0.18) * l.a),
                }}
              />
            );
          })}

          {REPORT.map((text, i) => {
            const at = lineAt(i);
            if (frame < at) return null;
            const typed = prog(frame, at, 0.35, fps);
            const banner = i === 0;
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  left: TEXT_X,
                  top: rowTop(i),
                  height: LH,
                  lineHeight: `${LH}px`,
                  fontFamily: FONT.mono,
                  fontSize: RS,
                  fontWeight: banner ? 600 : 400,
                  whiteSpace: "pre",
                  color: banner ? ROLE.diverged : C.text,
                  opacity: (banner ? 1 - ghost : 1) * rowOpacity(i),
                  clipPath: `inset(0 ${(1 - typed) * 100}% 0 0)`,
                }}
              >
                <ReportLine text={text} color={C.text} numbers={numbers} />
              </div>
            );
          })}

          {/* The ghost: what a green report's banner would say, over the same block. */}
          {ghost > 0 && (
            <div
              style={{
                position: "absolute",
                left: TEXT_X,
                top: rowTop(0),
                height: LH,
                lineHeight: `${LH}px`,
                fontFamily: FONT.mono,
                fontSize: RS,
                fontWeight: 600,
                whiteSpace: "pre",
                color: ROLE.equivalent,
                opacity: ghost * 0.9,
                textShadow: `0 0 ${18 * ghost}px ${tint(ROLE.equivalent, 0.6)}`,
              }}
            >
              {GHOST}
            </div>
          )}
        </div>
      )}

      {/* One cent: beside the two divergence lines, clear of their highlights, in the label column. */}
      {centLabel > 0 && (
        <div
          style={{
            position: "absolute",
            left: BLOCK_RIGHT + 36,
            top: rowTop(8),
            transform: `translate(0, -50%) translateX(${(1 - centLabel) * -12}px)`,
            fontFamily: FONT.serif,
            fontStyle: "italic",
            fontSize: 38,
            color: ROLE.candidate,
            opacity: centLabel,
            whiteSpace: "nowrap",
          }}
        >
          +1 cent
        </div>
      )}

      <Svg>
        <Line from={[bLeft, bTop]} to={[bLeft, bBottom]} at={measured} dur={0.6} color={C.text} width={bWidth} />
        <Line from={[bLeft, bTop]} to={[bLeft + 14, bTop]} at={measured} dur={0.2} color={C.text} width={bWidth} />
        <Line from={[bLeft, bBottom]} to={[bLeft + 14, bBottom]} at={measured + s(0.45)} dur={0.2} color={C.text} width={bWidth} />
        <Line from={[BLOCK_RIGHT, bTop]} to={[BLOCK_RIGHT, bBottom]} at={measured + s(0.2)} dur={0.6} color={C.text} width={bWidth} />
        <Line from={[BLOCK_RIGHT, bTop]} to={[BLOCK_RIGHT - 14, bTop]} at={measured + s(0.2)} dur={0.2} color={C.text} width={bWidth} />
        <Line from={[BLOCK_RIGHT, bBottom]} to={[BLOCK_RIGHT - 14, bBottom]} at={measured + s(0.65)} dur={0.2} color={C.text} width={bWidth} />
      </Svg>
      {blockLabel > 0 && (
        <div
          style={{
            position: "absolute",
            left: BLOCK_RIGHT + 36,
            top: (bTop + bBottom) / 2,
            transform: `translate(0, -50%) translateX(${(1 - blockLabel) * -12}px)`,
            fontFamily: FONT.serif,
            fontStyle: "italic",
            fontSize: 36,
            color: C.text,
            opacity: blockLabel,
            whiteSpace: "nowrap",
          }}
        >
          qualification block
        </div>
      )}
    </>
  );
};
