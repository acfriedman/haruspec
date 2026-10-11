import React from "react";
import { useScene, Svg, Line, Arrow, C, FONT, mix, prog } from "#kit";
import { ROLE, Verdict, useAppear } from "./shared";

// Scene 6 · unstable. The two report excerpts are quoted exactly from the visual brief: the coin-flip
// and minting subjects of Tests/SpecTests/StabilityTests.swift, as Stability.swift and
// UncontrolledSeam.swift render them. Two lines too long for the frame are re-broken at a word boundary
// (labelled "wrapped"); `wrap` only splits them, so the pieces rejoin into the original line.

const V = ROLE.unstable;

/** Report-card type: 20 px mono, the size the longest exact line needs to fit the frame. */
const MONO = 20;
const LH = 31;
const HEADER = 52;
/** A report card's height for `rows` lines: borders, header and its rule, padding, body. */
const cardH = (rows: number) => 3 + HEADER + 2 + 18 + rows * LH + 18 + 3;

/** Splits `line` at the space after `after`; the rest continues on a line indented `indent` spaces. */
function wrap(line: string, after: string, indent: number): [string, string] {
  const i = line.indexOf(after) + after.length;
  return [line.slice(0, i), " ".repeat(indent) + line.slice(i + 1)];
}

const WARN =
  "    ⚠︎ identical replays disagreed — an axis of nondeterminism is unmodeled (an uncontrolled seam, or a missing projection); the delta above points at it";
const COIN_FLIP = [
  "🌀 UNSTABLE  stability.subject → stability.subject",
  "  …",
  "  stability: 2 distinct outcomes across 3 replays of identical inputs:",
  "    runs 1,3 → diverged:",
  "      valueMismatch Total · value: baseline=42 candidate=43",
  "    run 2 → equivalent",
  ...wrap(WARN, "projection);", 6),
  "  uncontrolled seams — values the subject makes up itself:",
  "    Total.value (int): a value the subject makes up itself — inject its source through the initializer and supply it with `.provides`",
];

const ORDER_ID =
  "    Total.orderID (UUID): a fresh identifier — inject its source (a `() -> UUID` the initializer takes, supplied by the spec's `.provides`)";
const [ORDER_A, ORDER_REST] = wrap(ORDER_ID, "identifier —", 6);
const MINTING = [
  "  stability: the baseline disagreed with itself on the failing input:",
  "  …",
  ORDER_A,
  ...wrap(ORDER_REST, "takes,", 6),
];

/** A run of text in one row: tinted in `color`, or, with `at`, underlined in `color` from that frame. */
type Span = { row: number; text: string; color: string; at?: number };

/** A terminal report excerpt that writes on row by row. `x`/`y` are its top-left. `marks` light whole
 *  rows; `note` is a small label after a row (not part of the report). */
const ReportCard: React.FC<{
  x: number;
  y: number;
  w: number;
  title: string;
  rows: string[];
  at: number;
  stagger?: number;
  spans?: Span[];
  marks?: { rows: number[]; at: number; color: string }[];
  note?: { row: number; text: string };
  opacity?: number;
}> = ({ x, y, w, title, rows, at, stagger = 0.1, spans = [], marks = [], note, opacity = 1 }) => {
  const { frame, fps } = useScene();
  const appear = useAppear(at, undefined, 0.5);
  if (appear <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width: w,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${C.dim}`,
        background: C.surface,
        opacity: appear * opacity,
        transform: `scale(${mix(0.97, 1, appear)})`,
        transformOrigin: "top left",
      }}
    >
      <div
        style={{
          height: HEADER,
          display: "flex",
          alignItems: "center",
          padding: "0 24px",
          borderBottom: `2px solid ${C.faint}`,
          fontFamily: FONT.mono,
          fontSize: 22,
          color: C.dim,
          whiteSpace: "nowrap",
        }}
      >
        {title}
      </div>
      <div style={{ padding: "18px 24px" }}>
        {rows.map((row, i) => {
          const p = prog(frame, at + Math.round(i * stagger * fps), 0.3, fps);
          const mark = marks.find((m) => m.rows.includes(i) && frame >= m.at);
          const mp = mark ? prog(frame, mark.at, 0.4, fps) : 0;
          const found = spans
            .filter((s) => s.row === i)
            .map((s) => ({ ...s, i: row.indexOf(s.text) }))
            .filter((s) => s.i >= 0)
            .sort((a, b) => a.i - b.i);
          const parts: React.ReactNode[] = [];
          let k = 0;
          found.forEach((s, j) => {
            if (s.i > k) parts.push(row.slice(k, s.i));
            const u = s.at === undefined ? 0 : prog(frame, s.at, 0.6, fps);
            parts.push(
              <span
                key={j}
                style={
                  s.at === undefined
                    ? { color: s.color }
                    : {
                        backgroundImage: `linear-gradient(${s.color}, ${s.color})`,
                        backgroundRepeat: "no-repeat",
                        backgroundPosition: "0 100%",
                        backgroundSize: `${u * 100}% 3px`,
                      }
                }
              >
                {s.text}
              </span>,
            );
            k = s.i + s.text.length;
          });
          if (k < row.length) parts.push(row.slice(k));
          return (
            <div
              key={i}
              style={{
                fontFamily: FONT.mono,
                fontSize: MONO,
                lineHeight: `${LH}px`,
                whiteSpace: "pre",
                fontFeatureSettings: '"calt" 0, "liga" 0',
                color: C.text,
                margin: "0 -10px",
                padding: "0 10px",
                borderRadius: 6,
                background: mark ? `${mark.color}${Math.round(mp * 0x38).toString(16).padStart(2, "0")}` : undefined,
                opacity: p,
                transform: `translateX(${(1 - p) * -10}px)`,
              }}
            >
              {parts}
              {note?.row === i && (
                <span style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 22, color: C.dim, marginLeft: 28, whiteSpace: "nowrap" }}>
                  {note.text}
                </span>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
};

/** A short label. `x`/`y` are its anchor point (vertical centre). */
const Label: React.FC<{
  x: number;
  y: number;
  children: string;
  at: number;
  out?: number;
  color?: string;
  anchor?: "left" | "center" | "right";
  mono?: boolean;
  opacity?: number;
}> = ({ x, y, children, at, out, color = C.dim, anchor = "center", mono = false, opacity = 1 }) => {
  const o = useAppear(at, out, 0.5) * opacity;
  if (o <= 0) return null;
  const tx = anchor === "left" ? "0" : anchor === "right" ? "-100%" : "-50%";
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(${tx}, -50%)`,
        fontFamily: mono ? FONT.mono : FONT.serif,
        fontStyle: mono ? "normal" : "italic",
        fontSize: mono ? 26 : 28,
        color,
        whiteSpace: "nowrap",
        opacity: o,
      }}
    >
      {children}
    </div>
  );
};

/** A small outlined chip. */
const Chip: React.FC<{ text: string; color: string; opacity: number }> = ({ text, color, opacity }) => (
  <span
    style={{
      fontFamily: FONT.mono,
      fontSize: 26,
      color,
      border: `2px solid ${color}`,
      background: `${color}14`,
      borderRadius: 999,
      padding: "2px 16px",
      opacity,
      transform: `translateY(${(1 - opacity) * 10}px)`,
      display: "inline-block",
      whiteSpace: "nowrap",
    }}
  >
    {text}
  </span>
);

/** The recorded inputs: a teal cassette whose reels turn by `spin` degrees. Centre at `x`/`y`. */
const Cassette: React.FC<{ x: number; y: number; o: number; spin: number }> = ({ x, y, o, spin }) => (
  <g opacity={o} transform={`translate(${x} ${y + (1 - o) * 16})`}>
    <rect x={-90} y={-58} width={180} height={116} rx={14} fill={`${ROLE.seam}22`} stroke={ROLE.seam} strokeWidth={4} />
    <rect x={-62} y={-36} width={124} height={48} rx={24} fill={C.bg} stroke={ROLE.seam} strokeWidth={2.5} />
    {[-34, 34].map((cx) => (
      <g key={cx} transform={`rotate(${spin} ${cx} -12)`}>
        <circle cx={cx} cy={-12} r={17} fill="none" stroke={ROLE.seam} strokeWidth={3} />
        {[0, 120, 240].map((a) => (
          <line
            key={a}
            x1={cx}
            y1={-12}
            x2={cx + 12 * Math.cos((a * Math.PI) / 180)}
            y2={-12 + 12 * Math.sin((a * Math.PI) / 180)}
            stroke={ROLE.seam}
            strokeWidth={2.5}
          />
        ))}
      </g>
    ))}
    <path d="M -50 58 L -38 34 L 38 34 L 50 58" fill="none" stroke={ROLE.seam} strokeWidth={3} />
  </g>
);

// Layout. Three replay lanes fed by one cassette; each ends in a verdict slot; a bracket asks them to agree.
const CASSETTE = { x: 220, y: 540 };
const LANES = [380, 540, 700];
const TRACK = { x0: 470, x1: 1290 };
const TICKS = [560, 740, 920, 1100];
const SLOT_X = 1480;
const BRACKET_X = 1650;
// The single-run inset beneath them.
const INSET = { left: 450, top: 830, w: 1270, h: 120, y: 890, x0: 640, x1: 1290, ticks: [740, 920, 1100] };
// The report cards.
const MERGED = { x: 960, y: 185 };
const CARD1 = { w: 1680, from: { x: 120, y: 250 }, to: { x: 80, y: 130 } };
const CARD2 = { x: 920, y: 580, w: 920 };
const RED = { x: 300, y: 720 };

export const Unstable: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const sameInputs = cue("same inputs");
  const answers = cue("different answers");
  const replays = cue("replays three times");
  const threeTimes = cue("three times");
  const everyPass = cue("every pass must agree");
  const mustAgree = cue("must agree");
  const values = cue("values");
  const here = cue("Here");
  const runOne = cue("one and three");
  const runThree = cue("three diverged");
  const runTwo = cue("run two matched");
  const without = cue("Without repetition");
  const whichever = cue("whichever color");
  const color = cue("color it landed");
  const landed = cue("landed on");
  const instead = cue("Instead");
  const delta = cue("the delta between runs");
  const names = cue("names the field that moved");
  const madeUp = cue("a value the subject");
  const onRed = cue("On a red");
  const live = cue("live campaign check");
  const reruns = cue("reruns the baseline against itself");
  const againstItself = cue("the baseline against");
  const fresh = cue("fresh identifier");
  const clock = cue("clock reading");
  const seams = cue("The seams video");

  // Dimming: the lanes step back for the single-run inset and leave when the pills merge.
  const dimIn = prog(frame, without, 0.6, fps);
  const dimBack = prog(frame, instead, 0.6, fps);
  const laneO = (1 - 0.72 * dimIn) * (1 - prog(frame, delta, 0.6, fps));
  const pillO = 1 - 0.72 * dimIn * (1 - dimBack);

  // The three lanes replay in step.
  const casO = useAppear(sameInputs, undefined, 0.5);
  const run = prog(frame, everyPass, 2.6, fps);
  const head = mix(TRACK.x0, TRACK.x1, run);
  const spin = frame >= everyPass ? run * 720 : 0;
  const tickO = prog(frame, replays + s(0.6), 0.4, fps);
  const outcomes = [
    { y: LANES[0], kind: "diverged" as const, at: runOne },
    { y: LANES[1], kind: "equivalent" as const, at: runTwo },
    { y: LANES[2], kind: "diverged" as const, at: runThree },
  ];

  // The bracket asks the lanes to agree, then turns violet when they don't.
  const bracketO = prog(frame, mustAgree, 0.5, fps);
  const disagree = prog(frame, runTwo + s(0.4), 0.5, fps);
  const bracket = `M ${BRACKET_X - 16} ${LANES[0] - 26} H ${BRACKET_X} V ${LANES[2] + 26} H ${BRACKET_X - 16} M ${BRACKET_X} ${LANES[1]} H ${BRACKET_X + 12}`;

  // The single run: whichever colour it landed on.
  const insetO = useAppear(without, instead, 0.5);
  const insetRun = prog(frame, without + s(0.4), (whichever - without - s(0.4)) / fps, fps);
  const insetHead = mix(INSET.x0, INSET.x1, insetRun);
  const flick = prog(frame, whichever, 0.15, fps);
  const green = prog(frame, color, 0.08, fps) * (1 - prog(frame, landed, 0.08, fps));

  // The three pills merge into one UNSTABLE.
  const merge = prog(frame, delta, 0.7, fps);
  const merged = prog(frame, delta + s(0.45), 0.35, fps);
  const unstableGlow = frame >= delta + s(0.5) ? 0.7 * (1 - prog(frame, delta + s(0.9), 1.2, fps)) : 0;

  // The live check: the first card slides aside for the second.
  const aside = prog(frame, reruns, 0.8, fps);
  const leftDim = mix(1, 0.5, prog(frame, fresh, 0.6, fps));

  return (
    <>
      {/* Three lanes, one cassette. */}
      <Svg opacity={laneO}>
        <Cassette x={CASSETTE.x} y={CASSETTE.y} o={casO} spin={spin} />
        {LANES.map((y, i) => (
          <Arrow
            key={`a${i}`}
            from={[CASSETTE.x + 102, CASSETTE.y + (y - CASSETTE.y) * 0.25]}
            to={[TRACK.x0 - 18, y]}
            at={replays + s(i * 0.12)}
            dur={0.5}
            color={ROLE.seam}
            width={3}
          />
        ))}
        {LANES.map((y, i) => (
          <Line key={`t${i}`} from={[TRACK.x0, y]} to={[TRACK.x1, y]} at={replays + s(0.2 + i * 0.12)} dur={0.6} color={C.faint} width={4} />
        ))}
        {outcomes.map(({ y, kind, at }, i) => {
          const tint = prog(frame, at, 0.5, fps);
          const slotO = prog(frame, answers + s(i * 0.12), 0.5, fps) * (1 - prog(frame, at, 0.3, fps));
          const tone = kind === "diverged" ? ROLE.diverged : ROLE.equivalent;
          return (
            <g key={`l${i}`}>
              {frame >= everyPass && <line x1={TRACK.x0} y1={y} x2={head} y2={y} stroke={C.dim} strokeWidth={4} />}
              {tint > 0 && <line x1={TRACK.x0} y1={y} x2={TRACK.x1} y2={y} stroke={tone} strokeWidth={5} opacity={tint} />}
              {TICKS.map((tx) => {
                const lit = frame >= everyPass && head >= tx;
                return (
                  <circle key={tx} cx={tx} cy={y} r={9} fill={lit ? (tint > 0.5 ? tone : C.text) : C.bg} stroke={lit ? C.text : C.dim} strokeWidth={2.5} opacity={tickO} />
                );
              })}
              {frame >= everyPass && <circle cx={head} cy={y} r={12} fill={C.text} opacity={1 - tint} />}
              {slotO > 0 && (
                <g opacity={slotO}>
                  <rect x={SLOT_X - 125} y={y - 27} width={250} height={54} rx={27} fill="none" stroke={C.dim} strokeWidth={2.5} strokeDasharray="8 8" />
                  <text x={SLOT_X} y={y + 1} fill={C.dim} fontFamily={FONT.mono} fontSize={30} textAnchor="middle" dominantBaseline="central">
                    ?
                  </text>
                </g>
              )}
            </g>
          );
        })}
        {bracketO > 0 && (
          <>
            <path d={bracket} fill="none" stroke={C.dim} strokeWidth={3} opacity={bracketO * (1 - disagree)} />
            <path d={bracket} fill="none" stroke={V} strokeWidth={4} opacity={bracketO * disagree} />
          </>
        )}
      </Svg>
      <div style={{ opacity: laneO }}>
        <Label x={CASSETTE.x} y={CASSETTE.y + 100} at={sameInputs} color={ROLE.seam}>
          identical inputs
        </Label>
        {LANES.map((y, i) => (
          <Label key={i} x={TRACK.x0} y={y - 40} at={threeTimes + s(i * 0.15)} anchor="left" mono>
            {`run ${i + 1}`}
          </Label>
        ))}
        <Label x={BRACKET_X + 28} y={LANES[1] - 20} at={mustAgree} out={runTwo + s(0.4)} anchor="left">
          must agree
        </Label>
        <Label x={BRACKET_X + 28} y={LANES[1] + 22} at={values} out={here} anchor="left">
          values too
        </Label>
        <Label x={BRACKET_X + 28} y={LANES[1]} at={runTwo + s(0.4)} anchor="left" color={V}>
          disagree
        </Label>
      </div>

      {/* The lane verdicts; at the delta they gather into one UNSTABLE. */}
      {outcomes.map(({ y, kind, at }, i) => (
        <Verdict
          key={i}
          x={mix(SLOT_X, MERGED.x, merge)}
          y={mix(y, MERGED.y, merge)}
          kind={kind}
          at={at}
          size={30}
          opacity={pillO * (1 - merged)}
        />
      ))}
      <Verdict x={MERGED.x} y={MERGED.y} kind="unstable" at={delta + s(0.5)} out={onRed} size={40} glow={unstableGlow} />

      {/* Without repetition: one run, whichever colour it landed on. */}
      {insetO > 0 && (
        <>
          <div
            style={{
              position: "absolute",
              left: INSET.left,
              top: INSET.top,
              width: INSET.w,
              height: INSET.h,
              boxSizing: "border-box",
              borderRadius: 16,
              border: `2px solid ${C.faint}`,
              background: C.surface,
              opacity: insetO,
            }}
          />
          <Label x={INSET.left + 32} y={INSET.y} at={without} out={instead} anchor="left" mono>
            one run
          </Label>
          <Svg opacity={insetO}>
            <line x1={INSET.x0} y1={INSET.y} x2={INSET.x1} y2={INSET.y} stroke={C.faint} strokeWidth={4} />
            <line x1={INSET.x0} y1={INSET.y} x2={insetHead} y2={INSET.y} stroke={C.dim} strokeWidth={4} />
            <line x1={INSET.x0} y1={INSET.y} x2={INSET.x1} y2={INSET.y} stroke={ROLE.diverged} strokeWidth={5} opacity={flick * (1 - green)} />
            <line x1={INSET.x0} y1={INSET.y} x2={INSET.x1} y2={INSET.y} stroke={ROLE.equivalent} strokeWidth={5} opacity={flick * green} />
            {INSET.ticks.map((tx) => (
              <circle key={tx} cx={tx} cy={INSET.y} r={9} fill={insetHead >= tx ? C.text : C.bg} stroke={insetHead >= tx ? C.text : C.dim} strokeWidth={2.5} />
            ))}
            <circle cx={insetHead} cy={INSET.y} r={12} fill={C.text} opacity={1 - flick} />
          </Svg>
          <Verdict x={SLOT_X} y={INSET.y} kind="diverged" size={30} opacity={insetO * flick * (1 - green)} />
          <Verdict x={SLOT_X} y={INSET.y} kind="equivalent" size={30} opacity={insetO * flick * green} />
        </>
      )}

      {/* The report: the delta between runs, and the field that moved. */}
      <ReportCard
        x={mix(CARD1.from.x, CARD1.to.x, aside)}
        y={mix(CARD1.from.y, CARD1.to.y, aside)}
        w={CARD1.w}
        title="Tests/SpecTests/StabilityTests.swift · coin-flip subject"
        rows={COIN_FLIP}
        at={delta + s(0.6)}
        spans={[
          { row: 0, text: "🌀 UNSTABLE", color: V },
          { row: 1, text: "…", color: C.dim },
          { row: 3, text: "diverged", color: ROLE.diverged },
          { row: 4, text: "baseline=42", color: ROLE.baseline },
          { row: 4, text: "candidate=43", color: ROLE.candidate },
          { row: 5, text: "equivalent", color: ROLE.equivalent },
          { row: 9, text: "Total.value (int)", color: V },
          { row: 9, text: "a value the subject makes up itself", color: V, at: madeUp },
        ]}
        marks={[{ rows: [9], at: names, color: V }]}
        note={{ row: 7, text: "wrapped" }}
        opacity={mix(1, 0.4, aside)}
      />

      {/* On a red, the live check reruns the baseline against itself. */}
      <Verdict x={RED.x} y={RED.y} kind="diverged" at={onRed} size={30} opacity={leftDim} />
      <Label x={RED.x} y={RED.y + 70} at={live} opacity={leftDim}>
        live campaign check
      </Label>
      <Svg>
        <Arrow from={[RED.x + 145, RED.y]} to={[CARD2.x - 20, RED.y]} at={reruns + s(0.2)} dur={0.6} color={ROLE.baseline} width={3} opacity={leftDim} />
      </Svg>
      <Label x={(RED.x + 145 + CARD2.x - 20) / 2} y={RED.y - 40} at={againstItself} color={ROLE.baseline} opacity={leftDim}>
        baseline vs baseline
      </Label>
      <ReportCard
        x={CARD2.x}
        y={CARD2.y}
        w={CARD2.w}
        title="live campaign check: a baseline that mints its own identifier"
        rows={MINTING}
        at={reruns + s(0.7)}
        stagger={0.12}
        spans={[
          { row: 1, text: "…", color: C.dim },
          { row: 2, text: "Total.orderID (UUID)", color: V },
          { row: 2, text: "a fresh identifier", color: V, at: fresh },
        ]}
        marks={[{ rows: [2, 3, 4], at: fresh, color: V }]}
        note={{ row: 4, text: "wrapped" }}
      />
      <div style={{ position: "absolute", left: CARD2.x, top: CARD2.y + cardH(MINTING.length) + 50, transform: "translateY(-50%)", display: "flex", gap: 20 }}>
        <Chip text="UUID()" color={ROLE.seam} opacity={prog(frame, fresh + s(0.2), 0.5, fps)} />
        <Chip text="Date()" color={ROLE.seam} opacity={prog(frame, clock, 0.5, fps)} />
      </div>

      {/* Where the how-to lives. */}
      {frame >= seams && (
        <div style={{ position: "absolute", left: 1840, top: 965, transform: "translate(-100%, -50%)", opacity: prog(frame, seams, 0.5, fps) }}>
          <Chip text="next: Seams" color={ROLE.seam} opacity={1} />
        </div>
      )}
    </>
  );
};
