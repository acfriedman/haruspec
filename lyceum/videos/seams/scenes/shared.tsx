// The visual vocabulary this video reuses across scenes, so the same idea always looks the same:
// role colours, standard positions, and recurring props. The official set (overview, specs, seams,
// verdicts) shares it: each video copies this file, so the four look like one piece.

import React from "react";
import { useScene, mix, prog, visibility, C, FONT } from "#kit";

/** Role colours. The baseline (the code you trust: legacy, or main) is blue, the candidate (the code
 *  you changed: the port, or the branch) pink. Seams and the values they carry are teal; a recorded
 *  plan is yellow. Verdicts: equivalent green, diverged red, cannot verify amber, unstable violet.
 *  `unknown` is the yellow of a question nobody can answer. */
export const ROLE = {
  baseline: C.blue,
  candidate: C.pink,
  seam: C.teal,
  plan: C.yellow,
  unknown: C.yellow,
  equivalent: C.green,
  diverged: C.red,
  cannotVerify: C.gold,
  unstable: C.purple,
} as const;

/** Standard positions: baseline on the left, candidate on the right. */
export const STAGE = { baseline: 520, candidate: 1400, y: 540 } as const;

/** The four verdicts, as the engine's report spells them (Core/DiffReport.swift), with their exit codes
 *  (CLI/main.swift). */
export const VERDICT = {
  equivalent: { text: "EQUIVALENT", icon: "✅", color: ROLE.equivalent, exit: 0 },
  diverged: { text: "DIVERGED", icon: "❌", color: ROLE.diverged, exit: 3 },
  cannotVerify: { text: "CANNOT-VERIFY", icon: "⚠️", color: ROLE.cannotVerify, exit: 4 },
  unstable: { text: "UNSTABLE", icon: "🌀", color: ROLE.unstable, exit: 5 },
} as const;

/** Fade-in progress times fade-out, for props that take `at` / `out`. */
export function useAppear(at?: number, out?: number, dur = 0.6) {
  const { frame, fps } = useScene();
  if (at !== undefined && frame < at) return 0;
  const p = at === undefined ? 1 : prog(frame, at, dur, fps);
  return p * visibility(frame, fps, undefined, out);
}

/** A verdict pill. `x`/`y` are its centre. */
export const Verdict: React.FC<{ x: number; y: number; kind: keyof typeof VERDICT; at?: number; out?: number; size?: number; glow?: number; opacity?: number }> = ({
  x,
  y,
  kind,
  at,
  out,
  size = 40,
  glow = 0,
  opacity = 1,
}) => {
  const o = useAppear(at, out, 0.45) * opacity;
  if (o <= 0) return null;
  const { text, icon, color } = VERDICT[kind];
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) scale(${mix(0.85, 1, Math.min(1, o))})`,
        fontFamily: FONT.mono,
        fontWeight: 600,
        fontSize: size,
        color,
        border: `3px solid ${color}`,
        background: `${color}1E`,
        borderRadius: 999,
        padding: `${size * 0.18}px ${size * 0.7}px`,
        whiteSpace: "nowrap",
        opacity: o,
        boxShadow: glow > 0 ? `0 0 ${40 * glow}px ${color}` : "none",
      }}
    >
      {icon} {text}
    </div>
  );
};

/** A source file: a rounded card with a file-name header and code beneath, in a role colour.
 *  `lines` is the code, one string per line; pass none for an empty file. `x`/`y` are its centre;
 *  the height follows the lines. `glow` (0…1) rings it. */
export const CodeCard: React.FC<{
  x: number;
  y: number;
  w: number;
  file: string;
  lines?: string[];
  color: string;
  at?: number;
  out?: number;
  size?: number;
  dim?: number;
  glow?: number;
  /** Lines (0-based) that light up, each from its own frame. */
  marks?: { line: number; at: number; color?: string }[];
  empty?: string;
}> = ({ x, y, w, file, lines = [], color, at, out, size = 26, dim = 0, glow = 0, marks = [], empty }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out);
  if (o <= 0) return null;
  const lh = size * 1.55;
  const header = 52;
  const body = Math.max(lines.length, empty ? 2 : 1) * lh + 36;
  const h = header + body;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${color}`,
        background: `linear-gradient(180deg, ${color}1C, ${color}08)`,
        opacity: o * mix(1, 0.3, dim),
        transform: `scale(${mix(0.94, 1, o)})`,
        boxShadow: glow > 0 ? `0 0 ${36 * glow}px ${color}` : "none",
        overflow: "hidden",
      }}
    >
      <div style={{ height: header, display: "flex", alignItems: "center", padding: "0 24px", borderBottom: `2px solid ${color}55`, fontFamily: FONT.mono, fontSize: 26, color }}>{file}</div>
      <div style={{ padding: "18px 24px" }}>
        {lines.map((ln, i) => {
          const mark = marks.filter((m) => m.line === i && frame >= m.at).at(-1);
          const mp = mark ? prog(frame, mark.at, 0.4, fps) : 0;
          return (
            <div
              key={i}
              style={{
                fontFamily: FONT.mono,
                fontSize: size,
                lineHeight: `${lh}px`,
                whiteSpace: "pre",
                color: C.text,
                background: mark ? `${mark.color ?? color}${Math.round(mp * 0x30).toString(16).padStart(2, "0")}` : undefined,
                borderRadius: 6,
              }}
            >
              {ln}
            </div>
          );
        })}
        {lines.length === 0 && empty && (
          <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, lineHeight: `${lh}px`, color: C.dim }}>{empty}</div>
        )}
      </div>
    </div>
  );
};

/** The test nobody can finish (illustrative, not real API): `#expect(cart.checkout() == ???)`. The `???`
 *  pulses `ROLE.unknown` from `pulseAt` and gives way to a baseline-blue chip reading `answer` from
 *  `answerAt`. `x`/`y` are its centre; `scale` shrinks it about its centre. */
export const TestCard: React.FC<{
  x: number;
  y: number;
  at?: number;
  out?: number;
  scale?: number;
  pulseAt?: number;
  answerAt?: number;
  answer?: string;
  dim?: number;
}> = ({ x, y, at, out, scale = 1, pulseAt, answerAt, answer = "the old code", dim = 0 }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out);
  if (o <= 0) return null;
  const w = 860;
  const h = 236;
  const pulsing = pulseAt !== undefined && frame >= pulseAt && (answerAt === undefined || frame < answerAt);
  const pulse = pulsing ? 0.5 + 0.5 * Math.sin(((frame - pulseAt!) / fps) * Math.PI * 2 * 0.9) : 0;
  const answered = answerAt === undefined ? 0 : prog(frame, answerAt, 0.6, fps);
  const mono = { fontFamily: FONT.mono, fontSize: 32, lineHeight: "52px", whiteSpace: "pre" as const };
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        boxSizing: "border-box",
        padding: "18px 34px",
        borderRadius: 16,
        border: `3px solid ${C.dim}`,
        background: C.surface,
        opacity: o * mix(1, 0.3, dim),
        transform: `scale(${scale * mix(0.94, 1, o)})`,
      }}
    >
      <div style={{ fontFamily: FONT.mono, fontSize: 26, color: C.dim, marginBottom: 6 }}>CartTests.swift</div>
      <div style={{ ...mono, color: C.text }}>
        <span style={{ color: C.purple }}>@Test</span> func checkoutTotal() {"{"}
      </div>
      <div style={{ ...mono, color: C.text }}>
        {"    #expect(cart.checkout() == "}
        {answered > 0 ? (
          <span
            style={{
              fontFamily: FONT.mono,
              fontSize: 28,
              color: ROLE.baseline,
              border: `2.5px solid ${ROLE.baseline}`,
              borderRadius: 999,
              padding: "0 14px",
              background: `${ROLE.baseline}1E`,
              opacity: answered,
              display: "inline-block",
              transform: `translateY(${(1 - answered) * 12}px)`,
            }}
          >
            {answer}
          </span>
        ) : (
          <span style={{ color: ROLE.unknown, textShadow: pulse > 0 ? `0 0 ${18 * pulse}px ${ROLE.unknown}` : "none", fontWeight: 600 }}>???</span>
        )}
        )
      </div>
      <div style={{ ...mono, color: C.text }}>{"}"}</div>
    </div>
  );
};

/** An ordering: operation labels as pills joined by arrows, laid out from `x` (its left edge, or its
 *  centre with `anchor="center"`). Each pill appears at its own frame in `ats` (or all at `at`). */
export const Ordering: React.FC<{ x: number; y: number; ops: string[]; at?: number; ats?: number[]; out?: number; size?: number; color?: string; anchor?: "left" | "center" }> = ({
  x,
  y,
  ops,
  at,
  ats,
  out,
  size = 26,
  color = C.text,
  anchor = "left",
}) => {
  const { frame, fps } = useScene();
  const fade = visibility(frame, fps, undefined, out);
  if (fade <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: anchor === "center" ? "translate(-50%, -50%)" : "translate(0, -50%)",
        display: "flex",
        alignItems: "center",
        gap: size * 0.45,
        opacity: fade,
        whiteSpace: "nowrap",
      }}
    >
      {ops.map((op, i) => {
        const t = ats?.[i] ?? at;
        const p = t === undefined ? 1 : prog(frame, t, 0.4, fps);
        return (
          <React.Fragment key={i}>
            {i > 0 && <span style={{ fontFamily: FONT.mono, fontSize: size, color: C.dim, opacity: p }}>→</span>}
            <span
              style={{
                fontFamily: FONT.mono,
                fontSize: size,
                color,
                border: `2px solid ${color}88`,
                borderRadius: 999,
                padding: `2px ${size * 0.5}px`,
                opacity: p,
                transform: `translateY(${(1 - p) * 10}px)`,
                display: "inline-block",
              }}
            >
              {op}
            </span>
          </React.Fragment>
        );
      })}
    </div>
  );
};

/** A trace strip: a narrow column of event rows (`kind label`), like a printed trace. Rows appear one
 *  by one from `at`, `stagger` seconds apart. `x`/`y` are its top-left. `marks` tints rows by index. */
export const TraceStrip: React.FC<{
  x: number;
  y: number;
  rows: string[];
  color: string;
  at?: number;
  out?: number;
  stagger?: number;
  w?: number;
  size?: number;
  title?: string;
  marks?: Record<number, string>;
  opacity?: number;
}> = ({ x, y, rows, color, at, out, stagger = 0.18, w = 360, size = 26, title, marks = {}, opacity = 1 }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.4) * opacity;
  if (o <= 0) return null;
  const start = at ?? 0;
  return (
    <div style={{ position: "absolute", left: x, top: y, width: w, opacity: o, borderLeft: `4px solid ${color}`, paddingLeft: 16 }}>
      {title && <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, color, marginBottom: 6 }}>{title}</div>}
      {rows.map((r, i) => {
        const p = prog(frame, start + Math.round(i * stagger * fps), 0.3, fps);
        const mark = marks[i];
        return (
          <div
            key={i}
            style={{
              fontFamily: FONT.mono,
              fontSize: size,
              lineHeight: `${size * 1.5}px`,
              color: mark ?? C.text,
              whiteSpace: "nowrap",
              opacity: p,
              transform: `translateX(${(1 - p) * -10}px)`,
            }}
          >
            {r}
          </div>
        );
      })}
    </div>
  );
};
