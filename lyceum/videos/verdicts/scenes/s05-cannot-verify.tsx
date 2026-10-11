import React from "react";
import { useScene, Svg, Text, C, FONT, LINE_HEIGHT, MONO_ADVANCE, mix, prog, track } from "#kit";
import { ROLE, Verdict } from "./shared";

// The report excerpt is `report()` for Tests/SpecTests/UnmatchedDomainTests.swift's `unmatched.typo`
// spec against its refactored cart, rendered by reading SpecTerminalReport.swift and
// Qualification.swift; the covered, declared-in and blind-spots lines are elided as "…". Beneath it,
// the four gaps that take a green away, and set apart, the one that only lowers the percentage.

const AMBER = ROLE.cannotVerify;

const REPORT = [
  "⚠️ CANNOT-VERIFY  unmatched.typo → unmatched.typo",
  "  explored: 1 run · all 1 ordering",
  "  coverage: 75% of 4 declared boundaries · domain-swept 0%",
  "    ⚠︎ declared domain matched nothing: qtyy (nothing read that seam)",
  "  …",
  "  seams: qtyy (declared, never read)",
  "  …",
  "  behavior matches across everything explored (0 divergences)",
];
const WARN_LINE = 3;
const SIZE = 26;
const LH = SIZE * LINE_HEIGHT;
const HEADER = 52;
const CARD = { left: 80, w: 1760, h: 6 + HEADER + 36 + REPORT.length * LH };
const CARD_TOP = { centred: 540 - CARD.h / 2, raised: 124 };

const CHIP_SIZE = 28;
const CHIP_CHAR = CHIP_SIZE * MONO_ADVANCE;
const CHIP_PAD = 20;
const CHIP_H = 56;
const CHIP_X = 80;
const ROWS = [610, 684, 758, 832];
const APART_Y = 948;
const chipWidth = (text: string) => text.length * CHIP_CHAR + 2 * CHIP_PAD;

const GAPS = [
  { text: "unrecorded reach: the replay fell back to a live read", mark: "live read" },
  { text: "declared domain matched nothing", mark: "declared domain" },
  { text: "blind spot: NotificationCenter.default", mark: "NotificationCenter.default" },
  { text: "no source found", mark: "source" },
];
const UNEXERCISED = "unexercised: lowers the percentage, never gates";

const BRACE_X = CHIP_X + Math.max(...GAPS.map((g) => chipWidth(g.text))) + 34;
const BRACE_D = 34;
const PILL = { x: BRACE_X + BRACE_D + 250, y: (ROWS[0] + ROWS[3]) / 2 };

const alpha = (a: number) => Math.round(Math.max(0, Math.min(1, a)) * 255).toString(16).padStart(2, "0");

/** A right-facing curly brace from (`x`, `y0`) to (`x`, `y1`), its tip `d` to the right. */
function bracePath(x: number, y0: number, y1: number, d: number, q = 22) {
  const ym = (y0 + y1) / 2;
  const xm = x + d / 2;
  return `M ${x} ${y0} Q ${xm} ${y0} ${xm} ${y0 + q} L ${xm} ${ym - q} Q ${xm} ${ym} ${x + d} ${ym} Q ${xm} ${ym} ${xm} ${ym + q} L ${xm} ${y1 - q} Q ${xm} ${y1} ${x} ${y1}`;
}

/** `text` with `needle` wrapped so it can underline from `at` (draws left to right). */
const Marked: React.FC<{ text: string; needle?: string; at?: number; color: string }> = ({ text, needle, at, color }) => {
  const { frame, fps } = useScene();
  const col = needle ? text.indexOf(needle) : -1;
  if (!needle || col < 0) return <>{text}</>;
  const u = at === undefined || frame < at ? 0 : prog(frame, at, 0.5, fps);
  return (
    <>
      {text.slice(0, col)}
      <span style={{ position: "relative" }}>
        {needle}
        {u > 0 && <span style={{ position: "absolute", left: 0, top: "calc(100% - 3px)", width: `${u * 100}%`, height: 4, borderRadius: 2, background: color }} />}
      </span>
      {text.slice(col + needle.length)}
    </>
  );
};

/** The report card: a neutral panel whose banner line is amber. The ⚠︎ line washes amber from
 *  `warnAt`; both `qtyy`s underline from `markAt`. */
const ReportCard: React.FC<{ top: number; at: number; todayAt: number; warnAt: number; markAt: number; focus: number }> = ({ top, at, todayAt, warnAt, markAt, focus }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const o = prog(frame, at, 0.6, fps);
  const today = frame < todayAt ? 0 : prog(frame, todayAt, 0.5, fps);
  const warn = frame < warnAt ? 0 : prog(frame, warnAt, 0.5, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: CARD.left,
        top,
        width: CARD.w,
        height: CARD.h,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${C.faint}`,
        background: C.surface,
        opacity: o * focus,
        transform: `translateY(${(1 - o) * 18}px)`,
        overflow: "hidden",
      }}
    >
      <div style={{ height: HEADER, boxSizing: "border-box", display: "flex", alignItems: "center", padding: "0 24px", borderBottom: `2px solid ${C.faint}`, whiteSpace: "pre" }}>
        <span style={{ fontFamily: FONT.mono, fontSize: 26, color: C.text }}>Tests/SpecTests/UnmatchedDomainTests.swift · report()</span>
        <span style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, color: C.dim, marginLeft: 28, opacity: today }}>today</span>
      </div>
      <div style={{ padding: "18px 24px" }}>
        {REPORT.map((ln, i) => {
          const banner = i === 0;
          const elided = ln.trim() === "…";
          const wash = i === WARN_LINE ? warn : 0;
          return (
            <div
              key={i}
              style={{
                fontFamily: FONT.mono,
                fontSize: SIZE,
                lineHeight: `${LH}px`,
                height: LH,
                whiteSpace: "pre",
                color: banner ? AMBER : elided ? C.dim : C.text,
                fontWeight: banner ? 600 : 400,
                background: wash > 0 ? `${AMBER}${alpha(wash * 0.22)}` : undefined,
                boxShadow: wash > 0 ? `inset 5px 0 0 ${AMBER}${alpha(wash)}` : undefined,
                borderRadius: 6,
                margin: "0 -12px",
                padding: "0 12px",
              }}
            >
              <Marked text={ln} needle={banner ? undefined : "qtyy"} at={markAt} color={AMBER} />
            </div>
          );
        })}
      </div>
    </div>
  );
};

/** A chip whose dashed slot shows from `slotAt` and whose text writes on in `stages` (each reveals
 *  up to column `upto` from its frame). `x` is its left edge, `y` its centre. */
const Chip: React.FC<{
  text: string;
  y: number;
  color: string;
  slotAt: number;
  stages: { upto: number; at: number }[];
  focus: number;
  mark?: string;
  markAt?: number;
}> = ({ text, y, color, slotAt, stages, focus, mark, markAt }) => {
  const { frame, fps } = useScene();
  if (frame < slotAt) return null;
  const w = chipWidth(text);
  const slot = prog(frame, slotAt, 0.4, fps);
  const box = frame < stages[0].at ? 0 : prog(frame, stages[0].at, 0.3, fps);
  let shown = 0;
  stages.forEach((st, i) => {
    const from = i === 0 ? 0 : stages[i - 1].upto;
    const chars = st.upto - from;
    if (frame >= st.at) shown += chars * prog(frame, st.at, 0.25 + chars * 0.014, fps);
  });
  const done = shown >= text.length - 0.01;
  return (
    <div style={{ position: "absolute", left: CHIP_X, top: y - CHIP_H / 2, width: w, height: CHIP_H }}>
      <div style={{ position: "absolute", inset: 0, boxSizing: "border-box", border: `2px dashed ${C.dim}`, borderRadius: 12, opacity: 0.55 * slot * (1 - box) }} />
      {box > 0 && (
        <div
          style={{
            position: "absolute",
            inset: 0,
            boxSizing: "border-box",
            border: `2.5px solid ${color}`,
            borderRadius: 12,
            background: `${color}1A`,
            opacity: box * focus,
            transform: `translateY(${(1 - box) * 6}px)`,
          }}
        >
          <div style={{ position: "absolute", left: CHIP_PAD - 2.5, top: 0, height: "100%", display: "flex", alignItems: "center" }}>
            <span
              style={{
                fontFamily: FONT.mono,
                fontSize: CHIP_SIZE,
                color,
                whiteSpace: "pre",
                clipPath: done ? "none" : `inset(0 ${(text.length - shown) * CHIP_CHAR}px 0 0)`,
              }}
            >
              <Marked text={text} needle={mark} at={markAt} color={color} />
            </span>
          </div>
        </div>
      )}
    </div>
  );
};

export const CannotVerify: React.FC = () => {
  const { frame, fps, cue } = useScene();

  const opening = cue("Cannot verify");
  const claim = cue("claim more than it saw");
  const mistake = cue("that mistake today");
  const today = cue("today");
  const names = cue("the report names it");
  const four = cue("Four gaps");
  const take = cue("take a green");
  const away = cue("away");
  const replay = cue("A replay that");
  const liveRead = cue("fell back to a live read");
  const declaredSeam = cue("A declared seam");
  const effect = cue("An effect");
  const escaping = cue("escaping capture");
  const notification = cue("global notification center");
  const andSource = cue("And source");
  const readAtAll = cue("read at all", { offset: -0.4 });
  const boundary = cue("A boundary the run");
  const lowers = cue("only lowers the percentage");
  const eachGap = cue("Each gap is named");
  const look = cue("where to look");

  // The card enters centred, then rises to make room for the gaps.
  const cardTop = track(frame, fps, [[0, CARD_TOP.centred], [cue("Four gaps", { offset: -0.4 }), CARD_TOP.raised]], 0.8);
  // The card steps back while the gaps are read, except for the one it shows (the declared domain).
  const cardFocus = track(frame, fps, [[0, 1], [replay, 0.55], [declaredSeam, 1], [effect, 0.55], [eachGap, 1]], 0.5);

  // Each gap's slot draws once the card has risen; each chip writes on as its clause is spoken.
  const slotAt = (i: number) => cue("Four gaps", { offset: 0.3 + i * 0.12 });
  const nextClause = [declaredSeam, effect, andSource, boundary];
  const stages = [
    [{ upto: GAPS[0].text.length, at: liveRead }],
    [{ upto: GAPS[1].text.length, at: declaredSeam }],
    [
      { upto: "blind spot: ".length, at: escaping },
      { upto: GAPS[2].text.length, at: notification },
    ],
    [{ upto: GAPS[3].text.length, at: readAtAll }],
  ];

  const braceP = frame < take ? 0 : prog(frame, take, 0.6, fps);

  return (
    <>
      {/* The verdict, alone, before the report that earns it. */}
      <Verdict x={960} y={470} kind="cannotVerify" size={60} at={opening} out={cue("that mistake today", { offset: -0.6 })} glow={0.5} />
      <Text x={960} y={590} size={32} italic color={C.dim} at={claim} out={cue("that mistake today", { offset: -0.6 })} reveal="fade">
        claims only what it saw
      </Text>

      <ReportCard top={cardTop} at={mistake} todayAt={today} warnAt={names} markAt={look} focus={cardFocus} />

      {GAPS.map((g, i) => (
        <Chip
          key={i}
          text={g.text}
          y={ROWS[i]}
          color={AMBER}
          slotAt={slotAt(i)}
          stages={stages[i]}
          focus={track(frame, fps, [[0, 1], [nextClause[i], 0.5], [eachGap, 1]], 0.5)}
          mark={g.mark}
          markAt={look}
        />
      ))}

      {/* The four gaps, bracketed, take the green away; the fifth sits outside the bracket. */}
      <Svg>
        {braceP > 0 && (
          <path
            d={bracePath(BRACE_X, ROWS[0] - CHIP_H / 2, ROWS[3] + CHIP_H / 2, BRACE_D)}
            pathLength={1}
            strokeDasharray={1}
            strokeDashoffset={1 - braceP}
            fill="none"
            stroke={AMBER}
            strokeWidth={3}
            strokeLinecap="round"
          />
        )}
      </Svg>
      <Verdict x={PILL.x} y={PILL.y} kind="equivalent" size={34} at={take} out={away} />
      <Verdict x={PILL.x} y={PILL.y} kind="cannotVerify" size={34} at={away} glow={mix(0.5, 0.25, prog(frame, away + Math.round(1.2 * fps), 1, fps))} />

      <Chip
        text={UNEXERCISED}
        y={APART_Y}
        color={C.dim}
        slotAt={boundary}
        stages={[{ upto: UNEXERCISED.length, at: lowers }]}
        focus={track(frame, fps, [[0, 1], [eachGap, 0.5]], 0.5)}
      />
    </>
  );
};
