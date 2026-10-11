import React from "react";
import { useScene, Svg, Box, Line, C, FONT, MONO_ADVANCE, prog, track, visibility } from "#kit";
import { ROLE, useAppear } from "./shared";

// Real output: `SpecVerdict.report()` rendered from Tests/SpecTests/Fixtures/diverged.result.json (the
// README's promo-cart spec with ordering exploration on, recorded on the rounding cart and replayed
// against one that truncates), quoted character for character. Scene 4 picks up this exact card, so its
// geometry (`REPORT_CARD`) must not move. The chip under the card is the wording Qualification.swift
// renders for an audited, empty blind-spot list.

export const REPORT = [
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

const FILE = "Tests/SpecTests/Fixtures/diverged.result.json";
const TITLE = `${FILE} · report()`;
const TITLE_SIZE = 26;

/** The report card: frame coordinates of its top-left, width, header and padding; 22 px mono lines on a
 *  38 px pitch. */
export const REPORT_CARD = { left: 80, top: 170, w: 1760, header: 56, padX: 48, padY: 22, size: 22, lineHeight: 38 } as const;

const SIZE = REPORT_CARD.size;
const CHAR = SIZE * MONO_ADVANCE;
const LH = REPORT_CARD.lineHeight;
const TEXT_LEFT = REPORT_CARD.left + REPORT_CARD.padX;
const BODY_TOP = REPORT_CARD.top + REPORT_CARD.header + REPORT_CARD.padY;
const CARD_H = REPORT_CARD.header + 2 * REPORT_CARD.padY + REPORT.length * LH;
const CARD_BOTTOM = REPORT_CARD.top + CARD_H;

/** The top of report line `i` (0-based). */
const lineTop = (i: number) => BODY_TOP + i * LH;

/** The qualification block: lines 2 to 8. */
const BLOCK = [1, 2, 3, 4, 5, 6, 7];
/** The part of the coverage line that stays dim. */
const DIM_TAIL = " · domain-swept 0%";

/** Where `needle` sits in report line `line`: its left edge and width, by column. */
function inLine(line: number, needle: string) {
  const col = REPORT[line].indexOf(needle);
  if (col < 0) throw new Error(`"${needle}" is not in report line ${line + 1}`);
  return { left: TEXT_LEFT + col * CHAR, width: needle.length * CHAR };
}

const dimStyle = { color: C.dim, opacity: 0.4 };

/** An underline that draws on under a substring of a report line from `at`, and fades at `out`. */
const Underline: React.FC<{ line: number; needle: string; at: number; out: number; color?: string }> = ({ line, needle, at, out, color = C.text }) => {
  const { frame, fps } = useScene();
  const { left, width } = inLine(line, needle);
  if (frame < at) return null;
  const o = visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left,
        top: lineTop(line) + LH - 7,
        width: width * prog(frame, at, 0.45, fps),
        height: 3,
        borderRadius: 2,
        background: color,
        opacity: o,
      }}
    />
  );
};

/** One report line, absolutely placed, in the given colour and opacity. */
const ReportLine: React.FC<{ i: number; color: string; opacity: number; weight?: number; shadow?: string; children?: React.ReactNode }> = ({ i, color, opacity, weight, shadow, children }) =>
  opacity <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: TEXT_LEFT,
        top: lineTop(i),
        height: LH,
        lineHeight: `${LH}px`,
        fontFamily: FONT.mono,
        fontSize: SIZE,
        fontWeight: weight,
        whiteSpace: "pre",
        color,
        opacity,
        textShadow: shadow,
      }}
    >
      {children ?? REPORT[i]}
    </div>
  );

const CHIP = "blind spots: audited — no blind spots declared";
const CHIP_SIZE = 26;
const CHIP_CHAR = CHIP_SIZE * MONO_ADVANCE;
const CHIP_PAD = 22;
const CHIP_LH = 40;
/** The chip's text starts under line 8's "blind spots:". */
const CHIP_LEFT = TEXT_LEFT + 2 * CHAR - CHIP_PAD - 3;
const CHIP_TOP = CARD_BOTTOM + 44;
const CHIP_W = CHIP.length * CHIP_CHAR + 2 * CHIP_PAD + 6;

export const Qualification: React.FC = () => {
  const { frame, fps, cue, narrationEnd } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const red = cue("green or red");
  const qual = cue("qualification block");
  const tests = cue("from the engine's tests");
  const explored = cue("Explored");
  const runs = cue("almost four hundred runs");
  const orderings = cue("all seven orderings");
  const variants = cue("fifty-five sets of seam values");
  const stability = cue("Stability");
  const replays = cue("three replays");
  const identical = cue("all identical");
  const coverage = cue("Coverage");
  const everyBoundary = cue("every declared boundary");
  const covered = cue("Covered");
  const theClass = cue("the class");
  const operations = cue("operations");
  const declared = cue("where they're declared");
  const seams = cue("Seams");
  const varied = cue("each seam that varied");
  const readings = cue("how many readings");
  const boundaryValues = cue("how many boundary values");
  const ran = cue("ran", { after: boundaryValues });
  const blind = cue("blind spots");
  const notAudited = cue("Not audited");
  const emptyList = cue("An empty list");
  const claim = cue("would be a claim");
  const someone = cue("someone looked");
  const nothing = cue("found nothing");
  // After the last word, the annotations clear so scene 4 opens on the bare card.
  const settle = Math.max(narrationEnd, cue("found nothing", { end: true })) + s(0.4);

  const cardIn = prog(frame, 0, 0.6, fps);

  // The banner flares once on "red".
  const flare = prog(frame, red, 0.35, fps) * (1 - prog(frame, red + s(0.9), 0.6, fps));

  // The header's file path brightens and underlines on "from the engine's tests".
  const pathOn = useAppear(tests, explored, 0.4);
  const pathLine = prog(frame, tests, 0.6, fps) * visibility(frame, fps, undefined, explored);

  // The highlight bar steps down the block as each label is spoken.
  const barY = track(
    frame,
    fps,
    [
      [0, lineTop(1)],
      [explored, lineTop(1)],
      [stability, lineTop(2)],
      [coverage, lineTop(3)],
      [covered, lineTop(4)],
      [declared, lineTop(5)],
      [seams, lineTop(6)],
      [blind, lineTop(7)],
    ],
    0.45,
  );
  const barO = useAppear(explored, settle, 0.4);

  // The hypothetical audited line slides in under the card.
  const chipIn = frame < emptyList ? 0 : prog(frame, emptyList, 0.6, fps);
  const chipO = chipIn * visibility(frame, fps, undefined, settle);
  const chipGlow = prog(frame, claim, 0.35, fps) * (1 - prog(frame, claim + s(1.0), 0.6, fps));
  const chipMark = (needle: string, at: number) => {
    const col = CHIP.indexOf(needle);
    if (frame < at) return null;
    return (
      <div
        style={{
          position: "absolute",
          left: CHIP_PAD + col * CHIP_CHAR,
          top: 10 + CHIP_LH - 6,
          width: needle.length * CHIP_CHAR * prog(frame, at, 0.45, fps),
          height: 3,
          borderRadius: 2,
          background: ROLE.equivalent,
        }}
      />
    );
  };

  const box = inLine(7, "not audited");

  return (
    <div style={{ position: "absolute", inset: 0, opacity: cardIn }}>
      {/* The card. */}
      <div
        style={{
          position: "absolute",
          left: REPORT_CARD.left,
          top: REPORT_CARD.top,
          width: REPORT_CARD.w,
          height: CARD_H,
          boxSizing: "border-box",
          borderRadius: 16,
          border: `2px solid ${C.faint}`,
          background: C.surface,
        }}
      />
      <div style={{ position: "absolute", left: REPORT_CARD.left, top: REPORT_CARD.top + REPORT_CARD.header, width: REPORT_CARD.w, height: 2, background: C.faint }} />
      <div
        style={{
          position: "absolute",
          left: REPORT_CARD.left + 24,
          top: REPORT_CARD.top,
          height: REPORT_CARD.header,
          lineHeight: `${REPORT_CARD.header}px`,
          fontFamily: FONT.mono,
          fontSize: TITLE_SIZE,
          color: C.dim,
          whiteSpace: "pre",
        }}
      >
        {TITLE}
      </div>
      {pathOn > 0 && (
        <>
          <div
            style={{
              position: "absolute",
              left: REPORT_CARD.left + 24,
              top: REPORT_CARD.top,
              height: REPORT_CARD.header,
              lineHeight: `${REPORT_CARD.header}px`,
              fontFamily: FONT.mono,
              fontSize: TITLE_SIZE,
              color: C.text,
              whiteSpace: "pre",
              opacity: pathOn,
            }}
          >
            {FILE}
          </div>
          <div
            style={{
              position: "absolute",
              left: REPORT_CARD.left + 24,
              top: REPORT_CARD.top + REPORT_CARD.header - 12,
              width: FILE.length * TITLE_SIZE * MONO_ADVANCE * pathLine,
              height: 3,
              borderRadius: 2,
              background: C.text,
              opacity: pathOn,
            }}
          />
        </>
      )}

      {/* The highlight bar, under the text. */}
      {barO > 0 && (
        <div
          style={{
            position: "absolute",
            left: REPORT_CARD.left + 14,
            top: barY,
            width: REPORT_CARD.w - 28,
            height: LH,
            boxSizing: "border-box",
            borderRadius: 6,
            borderLeft: `4px solid ${C.text}44`,
            background: `${C.text}10`,
            opacity: barO,
          }}
        />
      )}

      <Svg>
        {/* A bracket gathers lines 2 to 8 as "the qualification block". */}
        <Line from={[112, lineTop(1) + 6]} to={[112, lineTop(8) - 6]} at={qual} out={explored} dur={0.5} color={C.dim} width={3} />
        <Line from={[112, lineTop(1) + 6]} to={[122, lineTop(1) + 6]} at={qual} out={explored} dur={0.3} color={C.dim} width={3} />
        <Line from={[112, lineTop(8) - 6]} to={[122, lineTop(8) - 6]} at={qual} out={explored} dur={0.3} color={C.dim} width={3} />
        {/* "Not audited" gets a grey box. */}
        <Box x={box.left + box.width / 2} y={lineTop(7) + LH / 2} w={box.width + 8} h={LH - 6} at={notAudited} out={settle} dur={0.5} color={C.dim} fill={`${C.dim}2A`} r={6} width={2.5} />
      </Svg>

      {/* Line 1: the banner, red. */}
      <ReportLine i={0} color={ROLE.diverged} opacity={1} weight={600} shadow={flare > 0 ? `0 0 ${18 * flare}px ${ROLE.diverged}` : undefined} />

      {/* Lines 2 to 8 start dim and brighten, top to bottom, on "qualification block". */}
      {BLOCK.map((i, k) => {
        const b = prog(frame, qual + s(0.08 * k), 0.4, fps);
        const tail = REPORT[i].endsWith(DIM_TAIL);
        return (
          <React.Fragment key={i}>
            <ReportLine i={i} color={dimStyle.color} opacity={dimStyle.opacity * (1 - b)} />
            <ReportLine i={i} color={C.text} opacity={b}>
              {tail ? (
                <>
                  {REPORT[i].slice(0, -DIM_TAIL.length)}
                  <span style={dimStyle}>{DIM_TAIL}</span>
                </>
              ) : undefined}
            </ReportLine>
          </React.Fragment>
        );
      })}

      {/* Lines 9 to 13 stay dim until scene 4. */}
      {REPORT.slice(8).map((_, k) => (
        <ReportLine key={k} i={8 + k} color={dimStyle.color} opacity={dimStyle.opacity} />
      ))}

      {/* The spoken substrings underline in turn. */}
      <Underline line={1} needle="385 runs" at={runs} out={stability} />
      <Underline line={1} needle="all 7 orderings" at={orderings} out={stability} />
      <Underline line={1} needle="55 seam variants" at={variants} out={stability} />
      <Underline line={2} needle="3/3" at={replays} out={coverage} />
      <Underline line={2} needle="identical replays" at={identical} out={coverage} />
      <Underline line={3} needle="100% of 4 declared boundaries" at={everyBoundary} out={covered} />
      <Underline line={4} needle="PromoCart" at={theClass} out={declared} />
      <Underline line={4} needle="3 ops" at={operations} out={declared} />
      <Underline line={6} needle="coffeeQty" at={varied} out={blind} />
      <Underline line={6} needle="2 positions" at={readings} out={blind} />
      <Underline line={6} needle="8 of 8 scheduled" at={boundaryValues} out={blind} />
      <Underline line={6} needle="47 combined" at={ran} out={blind} />

      {/* What an audited, empty list would print. */}
      {chipO > 0 && (
        <>
          <div
            style={{
              position: "absolute",
              left: CHIP_LEFT,
              top: CHIP_TOP,
              width: CHIP_W,
              boxSizing: "border-box",
              padding: `10px ${CHIP_PAD}px`,
              border: `3px solid ${ROLE.equivalent}`,
              borderRadius: 12,
              background: `${ROLE.equivalent}14`,
              fontFamily: FONT.mono,
              fontSize: CHIP_SIZE,
              lineHeight: `${CHIP_LH}px`,
              color: C.text,
              whiteSpace: "pre",
              opacity: chipO,
              transform: `translateY(${(1 - chipIn) * 28}px)`,
              boxShadow: chipGlow > 0 ? `0 0 ${30 * chipGlow}px ${ROLE.equivalent}88` : "none",
            }}
          >
            {CHIP}
            {chipMark("audited", someone)}
            {chipMark("no blind spots declared", nothing)}
          </div>
          <div
            style={{
              position: "absolute",
              left: CHIP_LEFT + CHIP_W + 32,
              top: CHIP_TOP + 3 + 10 + CHIP_LH / 2,
              transform: `translateY(-50%)`,
              fontFamily: FONT.serif,
              fontStyle: "italic",
              fontSize: 26,
              color: C.dim,
              whiteSpace: "nowrap",
              opacity: chipO * prog(frame, emptyList + s(0.4), 0.5, fps),
            }}
          >
            an audited, empty list
          </div>
        </>
      )}
    </div>
  );
};
