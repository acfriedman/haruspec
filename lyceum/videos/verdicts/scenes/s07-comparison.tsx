import React from "react";
import { useScene, Svg, Box, Arrow, Text, C, FONT, LINE_HEIGHT, MONO_ADVANCE, mix, prog, lin, track, visibility } from "#kit";
import { CodeCard, TraceStrip, ROLE, useAppear } from "./shared";

// The JSON is Examples/checkout-comparison.json verbatim. The Swift chips are spelled as in
// Sources/Spec/Spec.swift, Sources/Core/Comparison.swift and Tests/CoreTests/DomainMigrationTests.swift;
// the two report lines are the divergence details from DomainMigrationTests.swift and
// SpawnEdgeDiffTests.swift. The trace rows, the order IDs and the arrow diagram are illustrative.

const JSON_LINES = [
  "{",
  '  "numericEpsilon": 0,',
  '  "timingBudgets": {',
  '    "CartService.checkout": 50',
  "  },",
  '  "unorderedGroups": [',
  '    ["CartDidChange", "AnalyticsDidTrack"]',
  "  ],",
  '  "ignoredKinds": []',
  "}",
];
const CARD = { x: 460, y: 452, w: 760, size: 26 };
const LH = CARD.size * LINE_HEIGHT;
const CHAR = CARD.size * MONO_ADVANCE;
const CARD_H = 52 + JSON_LINES.length * LH + 36;
const CODE_LEFT = CARD.x - CARD.w / 2 + 3 + 24;
/** The top of a line of the JSON card. */
const lineTop = (i: number) => CARD.y - CARD_H / 2 + 3 + 53 + 18 + i * LH;

const IGNORE = '.ignore(notifications: ["AnalyticsDidTrack"])';
const PER_DOMAIN = "Comparison(concurrency: .perDomain)";
const MOVES = 'Moves("CartDidChange", from: .queue("com.emporium.cart"), to: .actor("CartActor"))';

const MOVED = "≠ CartDidChange: ran on a different domain (queue(serial):com.emporium.cart → actor:CartActor#1)";
const DROPPED_HEAD = "≠ Inventory.reserve: synchronization dropped: Cart.checkout → Inventory.reserve held in baseline (spawn edge from #0);";
const DROPPED_TAIL = "the candidate leaves them concurrent";
const REPORT = { x: 80, size: 24 };
const RCHAR = REPORT.size * MONO_ADVANCE;

const STRIP = { x: 1100, w: 420, row: 39, text: 1120 };
const BASE_TOP = 285;
const CAND_TOP = 575;
const BASE_ROWS = ["post CartDidChange", "post AnalyticsDidTrack", "call checkout", "orderID = 4B1A", "return 1799"];
const CAND_ROWS = ["post AnalyticsDidTrack", "post CartDidChange", "call checkout", "orderID = 9E07", "return 1799"];
const SEAM_ROW = 3;
const SEAM_COL = CAND_ROWS[SEAM_ROW].indexOf("9E07");
const LENS_R = 1504;
const LABEL_X = 1528;

const LANE = { x: 1000, w: 840, h: 72, label1: 220, y1: 290, label2: 390, y2: 460 };
const CHIP_FROM = { x: 1180, y: LANE.y1 };
const CHIP_TO = { x: 1500, y: LANE.y2 };

const NODE = { y: 360, h: 64, a: { x: 220, w: 280 }, b: { x: 720, w: 320 } };
const EDGE = { from: NODE.a.x + NODE.a.w / 2 + 8, to: NODE.b.x - NODE.b.w / 2 - 8 };

/** A key of the JSON card lighting up: a soft band over its lines and a ring around the key. */
const KeyGlow: React.FC<{ line: number; needle: string; through: number; at: number; out: number }> = ({ line, needle, through, at, out }) => {
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  const col = JSON_LINES[line].indexOf(needle);
  const top = lineTop(line);
  return (
    <>
      <div
        style={{
          position: "absolute",
          left: CODE_LEFT - 10,
          top,
          width: CARD.w - 54 + 20,
          height: (through - line + 1) * LH,
          borderRadius: 8,
          background: `${C.text}10`,
          opacity: o,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: CODE_LEFT + col * CHAR - 7,
          top: top + 3,
          width: needle.length * CHAR + 14,
          height: LH - 6,
          boxSizing: "border-box",
          borderRadius: 8,
          border: `2px solid ${C.text}`,
          background: `${C.text}16`,
          boxShadow: `0 0 ${20 * o}px ${C.text}77`,
          opacity: o,
        }}
      />
    </>
  );
};

/** A line of Swift in a chip, written on left to right. `x` is its left edge, `y` its centre. */
const SwiftChip: React.FC<{ x: number; y: number; text: string; at: number; out?: number; dur?: number }> = ({ x, y, text, at, out, dur = 1 }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.3);
  if (o <= 0) return null;
  const p = lin(frame, at, dur, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translateY(-50%)",
        border: `2px solid ${C.dim}`,
        borderRadius: 12,
        background: C.surface,
        padding: "6px 16px",
        opacity: o,
        fontFamily: FONT.mono,
        fontSize: 26,
        lineHeight: "39px",
        whiteSpace: "pre",
        color: C.text,
      }}
    >
      <span style={{ display: "inline-block", clipPath: `inset(-6px ${(1 - p) * 100}% -6px -6px)` }}>{text}</span>
    </div>
  );
};

/** A report line, written on at a steady pace (or faded in whole with `fade`). `x` is its left edge,
 *  `y` its centre. */
const ReportLine: React.FC<{ x: number; y: number; text: string; color: string; at: number; dur?: number; out?: number; fade?: boolean; glow?: number }> = ({
  x,
  y,
  text,
  color,
  at,
  dur = 1,
  out,
  fade = false,
  glow = 0,
}) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const o = (fade ? prog(frame, at, 0.6, fps) : 1) * visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  const p = fade ? 1 : lin(frame, at, dur, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translateY(-50%)",
        fontFamily: FONT.mono,
        fontSize: REPORT.size,
        lineHeight: `${REPORT.size * 1.5}px`,
        whiteSpace: "pre",
        color,
        opacity: o,
        clipPath: `inset(-24px ${(1 - p) * 100}% -24px -24px)`,
        textShadow: glow > 0 ? `0 0 ${16 * glow}px ${color}` : "none",
      }}
    >
      {text}
    </div>
  );
};

/** The `CartDidChange` event as a chip on a lane. `x`/`y` are its centre. */
const EventChip: React.FC<{ x: number; y: number; color: string; opacity: number; ghost?: boolean }> = ({ x, y, color, opacity, ghost = false }) =>
  opacity <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translate(-50%, -50%)",
        fontFamily: FONT.mono,
        fontSize: 26,
        lineHeight: "36px",
        color: ghost ? C.dim : C.text,
        border: `2.5px ${ghost ? "dashed" : "solid"} ${color}`,
        background: ghost ? "transparent" : `${color}1E`,
        borderRadius: 999,
        padding: "2px 16px",
        whiteSpace: "nowrap",
        opacity,
      }}
    >
      CartDidChange
    </div>
  );

export const Comparison: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const differences = cue("some differences");
  const behavior = cue("aren't behavior");
  const declares = cue("declares them once");
  const numeric = cue("numeric jitter");
  const timing = cue("a timing budget");
  const independent = cue("two independent");
  const either = cue("either order");
  const noisy = cue("a noisy channel");
  const perDomain = cue("per concurrency domain");
  const diff = cue("at diff time");
  const complete = cue("stay complete");
  const read = cue("only changes how");
  const excuse = cue("excuse a value");
  const value = cue("a value", { after: excuse });
  const seam = cue("uncontrolled seam");
  const concurrency = cue("concurrency changes");
  const work = cue("work that moved");
  const moved = cue("moved to another domain");
  const sync = cue("a synchronization");
  const dropped = cue("dropped");
  const gates = cue("gates");
  const meant = cue("until you say");

  // The left half: the comparison file, dimmed once the lens takes over, gone for the report lines.
  const leftOpacity = track(frame, fps, [[0, 1], [diff, 0.55], [concurrency, 0.22]], 0.6) * (1 - prog(frame, work, 0.5, fps));

  // The right half of the first phase clears for the lanes.
  const rightOpacity = 1 - prog(frame, concurrency, 0.5, fps);

  // The red swap mark: in on "behavior", a nudge on "two independent", gone when the bracket closes.
  const swapIn = prog(frame, behavior, 0.4, fps);
  const swapNudge = Math.sin(Math.PI * lin(frame, independent, 0.8, fps));
  const swap = swapIn * (1 - prog(frame, either + s(0.3), 0.5, fps));

  // The dashed bracket closes over the pair, then becomes the lens.
  const bracketIn = prog(frame, either, 0.6, fps);
  const bracket = bracketIn * (1 - prog(frame, diff, 0.4, fps));
  const pairMid = CAND_TOP + STRIP.row;
  const half = mix(80, 37, bracketIn);

  const lensIn = prog(frame, diff, 0.7, fps);
  const lensL = mix(LENS_R - 22, STRIP.x - 10, lensIn);
  const lensTop = track(frame, fps, [[0, CAND_TOP - 3], [excuse, CAND_TOP + SEAM_ROW * STRIP.row - 3]], 1.4);
  const lensBottom = track(frame, fps, [[0, CAND_TOP + 2 * STRIP.row + 3], [excuse, CAND_TOP + 5 * STRIP.row + 3]], 1.4);

  // The value the subject made up pulses violet, above the lens.
  const pulse = frame >= value ? 0.5 + 0.5 * Math.sin(((frame - value) / fps) * Math.PI * 2 * 0.8) : 0;
  const cell = prog(frame, value, 0.4, fps);
  const cellTop = CAND_TOP + SEAM_ROW * STRIP.row;

  // Concurrency: the event slides from the queue's lane to the actor's.
  const lanesAt = concurrency + s(0.5);
  const slide = prog(frame, moved, 0.9, fps);
  const chipIn = prog(frame, lanesAt + s(0.6), 0.4, fps);
  const chipX = mix(CHIP_FROM.x, CHIP_TO.x, slide);
  const chipY = mix(CHIP_FROM.y, CHIP_TO.y, slide);

  // The synchronization edge snaps on "dropped".
  const snap = prog(frame, dropped, 0.3, fps);
  const gap = mix(0, 16, snap);
  const sag = mix(0, 9, snap);
  const edgeMid = (EDGE.from + EDGE.to) / 2;

  const glow = prog(frame, gates, 0.35, fps) * (1 - prog(frame, gates + s(0.8), 0.6, fps));
  const movedAt = moved + s(0.4);
  const droppedAt = sync + s(0.5);
  const tailAt = droppedAt + s(1.2);

  return (
    <>
      {/* The comparison file and its two Swift spellings. */}
      {leftOpacity > 0 && (
        <div style={{ opacity: leftOpacity }}>
          <CodeCard x={CARD.x} y={CARD.y} w={CARD.w} file="Examples/checkout-comparison.json" lines={JSON_LINES} color={C.text} size={CARD.size} at={declares} />
          <KeyGlow line={1} needle='"numericEpsilon"' through={1} at={numeric} out={timing} />
          <KeyGlow line={2} needle='"timingBudgets"' through={4} at={timing} out={independent} />
          <KeyGlow line={5} needle='"unorderedGroups"' through={7} at={either} out={noisy} />
          <SwiftChip x={80} y={756} text={IGNORE} at={noisy} dur={1.2} />
          <SwiftChip x={80} y={836} text={PER_DOMAIN} at={perDomain} dur={0.9} />
        </div>
      )}

      {/* Two recorded traces, the candidate's first two notifications swapped. */}
      {rightOpacity > 0 && (
        <div style={{ opacity: rightOpacity }}>
          <Text x={STRIP.x} y={BASE_TOP - 26} size={26} italic color={ROLE.baseline} anchor="left" at={s(0.05)} reveal="fade">
            baseline
          </Text>
          <TraceStrip x={STRIP.x} y={BASE_TOP} w={STRIP.w} rows={BASE_ROWS} color={ROLE.baseline} at={s(0.05)} />
          <Text x={STRIP.x} y={CAND_TOP - 26} size={26} italic color={ROLE.candidate} anchor="left" at={differences} reveal="fade">
            candidate
          </Text>
          <TraceStrip x={STRIP.x} y={CAND_TOP} w={STRIP.w} rows={CAND_ROWS} color={ROLE.candidate} at={differences} />

          {/* The swap: a red tint on the pair and a curved double arrow beside it. */}
          {swap > 0 && (
            <div
              style={{
                position: "absolute",
                left: STRIP.x + 8,
                top: CAND_TOP + 1,
                width: STRIP.w - 30,
                height: 2 * STRIP.row - 2,
                borderRadius: 6,
                background: `${ROLE.diverged}1C`,
                opacity: swap,
              }}
            />
          )}
          <Svg opacity={swap}>
            {(() => {
              const x = STRIP.x - 14;
              const y0 = CAND_TOP + STRIP.row / 2;
              const y1 = y0 + STRIP.row;
              const bow = x - 30 - 10 * swapNudge;
              return (
                <g stroke={ROLE.diverged} strokeWidth={3.5} fill="none" strokeLinecap="round">
                  <path d={`M ${x} ${y0} C ${bow} ${y0}, ${bow} ${y1}, ${x} ${y1}`} />
                  <path d={`M ${x - 11} ${y0 - 7} L ${x} ${y0} L ${x - 11} ${y0 + 7}`} />
                  <path d={`M ${x - 11} ${y1 - 7} L ${x} ${y1} L ${x - 11} ${y1 + 7}`} />
                </g>
              );
            })()}
          </Svg>

          {/* The unordered group's dashed bracket closes over the pair. */}
          <Svg opacity={bracket}>
            <path
              d={`M ${LENS_R - 22} ${pairMid - half} L ${LENS_R - 4} ${pairMid - half} L ${LENS_R - 4} ${pairMid + half} L ${LENS_R - 22} ${pairMid + half}`}
              stroke={C.text}
              strokeWidth={3}
              strokeDasharray="9 7"
              fill="none"
            />
          </Svg>
          <Text x={LABEL_X} y={pairMid} size={26} italic color={C.dim} anchor="left" at={either + s(0.3)} out={diff} reveal="fade">
            unordered group
          </Text>

          {/* The comparison as a lens, floating over traces that stay whole beneath it. */}
          {lensIn > 0 && (
            <div
              style={{
                position: "absolute",
                left: lensL,
                top: lensTop,
                width: LENS_R - lensL,
                height: lensBottom - lensTop,
                boxSizing: "border-box",
                borderRadius: 14,
                border: `2px solid ${C.dim}`,
                background: `${C.text}0A`,
                boxShadow: `0 0 28px ${C.text}14`,
                opacity: lensIn,
              }}
            />
          )}
          <Text x={LABEL_X} y={CAND_TOP + STRIP.row / 2} size={26} italic color={C.dim} anchor="left" at={diff + s(0.5)} out={excuse} reveal="fade">
            comparison
          </Text>
          <Text x={LABEL_X} y={CAND_TOP + STRIP.row * 1.5} size={26} italic color={ROLE.equivalent} anchor="left" at={read} out={excuse} reveal="fade">
            read as equal
          </Text>
          <Text x={STRIP.x} y={CAND_TOP + 5 * STRIP.row + 46} size={26} italic color={C.dim} anchor="left" at={complete} reveal="fade">
            both traces complete
          </Text>

          {/* The value nobody controlled: violet, and the lens doesn't touch it. */}
          {cell > 0 && (
            <div
              style={{
                position: "absolute",
                left: STRIP.text + SEAM_COL * CHAR - 7,
                top: cellTop + 2,
                height: STRIP.row - 4,
                boxSizing: "border-box",
                padding: "0 5px",
                borderRadius: 8,
                border: `2.5px solid ${ROLE.unstable}`,
                background: `linear-gradient(${ROLE.unstable}38, ${ROLE.unstable}38), ${C.bg}`,
                boxShadow: `0 0 ${10 + 22 * pulse}px ${ROLE.unstable}`,
                fontFamily: FONT.mono,
                fontSize: 26,
                lineHeight: `${STRIP.row - 9}px`,
                color: ROLE.unstable,
                whiteSpace: "pre",
                opacity: cell,
              }}
            >
              9E07
            </div>
          )}
          <Text x={LABEL_X} y={cellTop + STRIP.row / 2} size={26} italic color={ROLE.unstable} anchor="left" at={seam}>
            uncontrolled seam
          </Text>
        </div>
      )}

      {/* Concurrency: two domains, and the event that moved between them. */}
      <Svg>
        <Box x={LANE.x + LANE.w / 2} y={LANE.y1} w={LANE.w} h={LANE.h} r={14} color={C.dim} fill={`${C.text}06`} at={lanesAt} dur={0.6} />
        <Box x={LANE.x + LANE.w / 2} y={LANE.y2} w={LANE.w} h={LANE.h} r={14} color={C.dim} fill={`${C.text}06`} at={lanesAt + s(0.25)} dur={0.6} />
      </Svg>
      <Text x={LANE.x} y={LANE.label1} size={26} font="mono" color={C.text} anchor="left" at={lanesAt} dur={0.7}>
        queue(serial):com.emporium.cart
      </Text>
      <Text x={LANE.x} y={LANE.label2} size={26} font="mono" color={C.text} anchor="left" at={lanesAt + s(0.25)} dur={0.5}>
        actor:CartActor
      </Text>
      <EventChip x={CHIP_FROM.x} y={CHIP_FROM.y} color={ROLE.baseline} opacity={0.75 * slide} ghost />
      <EventChip x={chipX} y={chipY} color={ROLE.baseline} opacity={chipIn * (1 - slide)} />
      <EventChip x={chipX} y={chipY} color={ROLE.candidate} opacity={slide} />
      <Text x={CHIP_FROM.x + 140} y={CHIP_FROM.y} size={26} italic color={ROLE.baseline} anchor="left" at={lanesAt + s(0.6)} reveal="fade">
        baseline
      </Text>
      <Text x={CHIP_TO.x + 140} y={CHIP_TO.y} size={26} italic color={ROLE.candidate} anchor="left" at={moved + s(0.8)} reveal="fade">
        candidate
      </Text>

      {/* The synchronization the port dropped: an edge that snaps. */}
      <Svg>
        <Box x={NODE.a.x} y={NODE.y} w={NODE.a.w} h={NODE.h} r={12} color={C.dim} fill={C.surface} at={sync} dur={0.5} />
        <Box x={NODE.b.x} y={NODE.y} w={NODE.b.w} h={NODE.h} r={12} color={C.dim} fill={C.surface} at={sync + s(0.15)} dur={0.5} />
        {frame < dropped && <Arrow from={[EDGE.from, NODE.y]} to={[EDGE.to, NODE.y]} at={sync + s(0.4)} dur={0.5} color={ROLE.baseline} width={4} />}
      </Svg>
      <Text x={NODE.a.x} y={NODE.y} size={26} font="mono" color={C.text} at={sync} reveal="fade">
        Cart.checkout
      </Text>
      <Text x={NODE.b.x} y={NODE.y} size={26} font="mono" color={C.text} at={sync + s(0.15)} reveal="fade">
        Inventory.reserve
      </Text>
      <Text x={edgeMid} y={NODE.y - 44} size={26} italic color={C.dim} at={sync + s(0.5)} reveal="fade">
        spawn edge
      </Text>
      {frame >= dropped && (
        <>
          <Svg opacity={mix(1, 0.5, snap)}>
            <g stroke={ROLE.baseline} strokeWidth={4} strokeLinecap="round" fill="none">
              <line x1={EDGE.from} y1={NODE.y} x2={edgeMid - gap} y2={NODE.y + sag} />
              <line x1={edgeMid + gap} y1={NODE.y + sag} x2={EDGE.to - 4} y2={NODE.y} />
            </g>
            <path d={`M ${EDGE.to} ${NODE.y} L ${EDGE.to - 14} ${NODE.y - 8} L ${EDGE.to - 14} ${NODE.y + 8} Z`} fill={ROLE.baseline} />
          </Svg>
          <div
            style={{
              position: "absolute",
              left: edgeMid,
              top: NODE.y + sag - 2,
              transform: `translate(-50%, -50%) scale(${mix(0.4, 1, snap)})`,
              fontFamily: FONT.mono,
              fontSize: 34,
              fontWeight: 700,
              color: ROLE.diverged,
              opacity: snap,
            }}
          >
            ✕
          </div>
        </>
      )}

      {/* The two report lines; the first turns grey once the move is declared. */}
      <ReportLine x={REPORT.x} y={600} text={MOVED} color={ROLE.diverged} at={movedAt} dur={1.3} out={meant} glow={glow} />
      <ReportLine x={REPORT.x} y={600} text={MOVED} color={C.dim} at={meant} fade />
      <ReportLine x={REPORT.x} y={680} text={DROPPED_HEAD} color={ROLE.diverged} at={droppedAt} dur={1.2} glow={glow} />
      <ReportLine x={REPORT.x + 2 * RCHAR} y={716} text={DROPPED_TAIL} color={ROLE.diverged} at={tailAt} dur={0.45} glow={glow} />
      <Text x={REPORT.x + (2 + DROPPED_TAIL.length) * RCHAR + 28} y={716} size={26} italic color={C.dim} anchor="left" at={tailAt + s(0.5)} reveal="fade">
        wrapped
      </Text>

      <SwiftChip x={80} y={826} text={MOVES} at={meant} dur={1.6} />
    </>
  );
};
