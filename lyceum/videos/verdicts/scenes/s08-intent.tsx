import React from "react";
import { useScene, Fade, Svg, Arrow, Text, Pill, C, FONT, LINE_HEIGHT, MONO_ADVANCE, mix, prog, track, along, visibility } from "#kit";
import { ROLE, VERDICT, Verdict, useAppear } from "./shared";

// The terminal is the example app's local-check dogfood (example-xcode-migration/docs/dogfood/
// local-check.md): the red line as scenario 3 logged it, the absorbed line as scenario 4 logged it. The
// offer is LocalCheckOutcome.swift's, simplified: the spec is shown as `Cart`, the name an unnamed
// Spec<Cart> takes today. The file section is what IntentDocument.swift writes on a save; its three HTML
// comment markers (begin, evidence, end) are drawn as grey rules. The August banner is scene 1's, quoted
// from commit 90614a6; the faint block is scene 3's qualification block (diverged.result.json).

const DECL = 'Changes("LoyaltyPointsEarned", field: "points").increases().only(in: "checkout")';
const OFFER = [
  "Cart: is this change the point of the branch?",
  "Declare it (edit it down to what you mean), then check again:",
  "    haruspec intent save Cart \\",
  `      '${DECL}'`,
  "If you did not mean to change behavior, this is a regression: fix the code, don't declare it.",
];
const DECL_COL = OFFER[3].indexOf(DECL);

const AUGUST = "EQUIVALENT  ·  64 runs · all 1 ordering x 64 seam variants  ·  coverage: 100%";
const QUALIFICATION = [
  "  explored: 385 runs · all 7 orderings × 55 seam variants",
  "  stability: 3/3 identical replays",
  "  coverage: 100% of 4 declared boundaries · domain-swept 0%",
  "  covered: PromoCart — 3 ops · 385 probes",
  "  declared in: PromoCart ← RoundBugCart (HaruspecSpecTests/SpecPrototypeTests.swift)",
  "  seams: coffeeQty (2 positions) · boundary edges 8 of 8 scheduled · 47 combined (every seam at once)",
  "  blind spots: not audited — capture completeness is unmeasured; effect channels outside the recorded seams may exist",
];

// The terminal: rows sit at fixed frame positions; the card behind them grows and shrinks.
const T = { x: 80, y: 130, size: 24, padX: 40, padY: 26, wide: 1440, narrow: 1080 };
const T_LH = T.size * LINE_HEIGHT;
const T_CH = T.size * MONO_ADVANCE;
const TEXT_X = T.x + T.padX;
const PROMPT_Y = T.y + T.padY;
const BANNER_Y = PROMPT_Y + T_LH + 8;
const BANNER_H = 58;
const BODY_Y = BANNER_Y + BANNER_H + 12;
const rowY = (i: number) => BODY_Y + i * T_LH;
/** The offer's rows sit under the red line and a blank row. */
const offerY = (k: number) => rowY(2 + k);
const termH = (rows: number) => BODY_Y + rows * T_LH + T.padY - T.y;

// The intent file card, at the right below the compacted terminal.
const F = { x: 710, y: 420, w: 1130, size: 22, header: 52, padY: 16, padX: 28, rule: 18 };
const F_LH = F.size * LINE_HEIGHT;
type FileRow = { rule: true } | { text: string; color?: string; weight?: number };
const FILE_ROWS: FileRow[] = [
  { rule: true },
  { text: "### `Cart`", weight: 700 },
  { text: "" },
  { text: "```haruspec-intent Cart", color: C.dim },
  { text: DECL },
  { text: "```", color: C.dim },
  { text: "" },
  { rule: true },
  { text: "_Not yet checked with these declarations — run `haruspec check`._", color: C.dim },
  { rule: true },
];
const DECL_ROW = 4;
/** Each file row's top, relative to the card's inner (inside-border) box. */
const FILE_TOPS = (() => {
  let y = F.header + F.padY;
  return FILE_ROWS.map((r) => {
    const top = y;
    y += "rule" in r ? F.rule : F_LH;
    return top;
  });
})();
const F_H = FILE_TOPS[FILE_TOPS.length - 1] + F.rule + F.padY + 6;
const F_TEXT_X = F.x + 3 + F.padX;

// The pull request description: a larger, faint sheet behind the file card, its block peeking out below.
const PR = { x: 500, y: 470, w: 1260, h: 512, size: 20 };
const PR_BLOCK = ["```haruspec-intent Cart", DECL, "```"];

type Seg = { t: string; color?: string; at?: number; weight?: number };

/** A mono line that types on, segment by segment; a segment with its own `at` waits for it. */
const Typed: React.FC<{ x: number; y: number; size: number; segs: Seg[]; at: number; cps?: number; color?: string; opacity?: number }> = ({
  x,
  y,
  size,
  segs,
  at,
  cps = 100,
  color = C.text,
  opacity = 1,
}) => {
  const { frame, fps } = useScene();
  if (frame < at || opacity <= 0) return null;
  let start = at;
  const spans = segs.map((sg, i) => {
    const s0 = Math.max(start, sg.at ?? start);
    const n = Math.max(0, Math.min(sg.t.length, Math.floor(((frame - s0) / fps) * cps)));
    start = s0 + Math.ceil((sg.t.length / cps) * fps);
    return (
      <span key={i} style={{ color: sg.color ?? color, fontWeight: sg.weight }}>
        {sg.t.slice(0, n)}
      </span>
    );
  });
  return (
    <div style={{ position: "absolute", left: x, top: y, fontFamily: FONT.mono, fontSize: size, lineHeight: `${size * LINE_HEIGHT}px`, whiteSpace: "pre", color, opacity }}>
      {spans}
    </div>
  );
};

/** A static mono line in coloured segments. */
const Mono: React.FC<{ x: number; y: number; size: number; segs: Seg[]; opacity?: number; style?: React.CSSProperties }> = ({ x, y, size, segs, opacity = 1, style }) =>
  opacity <= 0 ? null : (
    <div style={{ position: "absolute", left: x, top: y, fontFamily: FONT.mono, fontSize: size, lineHeight: `${size * LINE_HEIGHT}px`, whiteSpace: "pre", color: C.text, opacity, ...style }}>
      {segs.map((sg, i) => (
        <span key={i} style={{ color: sg.color, fontWeight: sg.weight }}>
          {sg.t}
        </span>
      ))}
    </div>
  );

/** The terminal's verdict banner: a tinted band with the verdict's icon and name. */
const TermBanner: React.FC<{ kind: keyof typeof VERDICT; w: number; opacity: number; glow?: number }> = ({ kind, w, opacity, glow = 0 }) => {
  if (opacity <= 0) return null;
  const { icon, text, color } = VERDICT[kind];
  return (
    <div
      style={{
        position: "absolute",
        left: T.x + 16,
        top: BANNER_Y,
        width: w - 32,
        height: BANNER_H,
        boxSizing: "border-box",
        borderLeft: `6px solid ${color}`,
        borderRadius: 8,
        background: `${color}1E`,
        display: "flex",
        alignItems: "center",
        paddingLeft: TEXT_X - (T.x + 16 + 6),
        fontFamily: FONT.mono,
        fontWeight: 600,
        fontSize: 30,
        color,
        whiteSpace: "pre",
        opacity,
        boxShadow: glow > 0 ? `0 0 ${34 * glow}px ${color}88` : "none",
      }}
    >
      {icon} {text}
    </div>
  );
};

export const Intent: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const intentAt = cue("intent is for");
  const branchAt = cue("branch doubles");
  const introOut = cue("and the check");
  const termAt = cue("the check goes", { offset: -0.2 });
  const redAt = cue("goes red");
  const sixtyAt = cue("sixty-three");
  const hundredAt = cue("a hundred and twenty-six");
  const offerAt = cue("The report ends");
  const cmdAt = cue("the command that");
  const fieldAt = cue("points field");
  const incAt = cue("increasing");
  const onlyAt = cue("only in checkout");
  const runAt = cue("Run it");
  const landsAt = cue("line lands");
  const fileAt = cue("your branch's intent file");
  const prAt = cue("pull request description");
  const nextAt = cue("next check");
  const absorbAt = cue("absorbs that change");
  const flipAt = cue("gates on whatever");
  const greenAt = cue("Green and it still");
  const showsAt = cue("still shows");
  const matchedAt = cue("nothing matched");
  const sixAt = cue("code six");
  const clearAt = cue("That August green");
  const clearOut = clearAt - s(0.25);
  const augustAt = cue("August");
  const strikeAt = cue("would read");
  const cvAt = cue("cannot verify");
  const provesAt = cue("verdict proves");
  const moreAt = cue("nothing more", { offset: -0.3 });

  // ── The terminal ────────────────────────────────────────────────────────────────────────────────
  const termO = useAppear(termAt, clearOut, 0.5);
  const cardW = track(frame, fps, [[0, T.narrow], [offerAt, T.wide], [landsAt + s(0.25), T.narrow]], 0.7);
  const cardH = track(frame, fps, [[0, termH(1)], [offerAt, termH(7)], [landsAt, termH(1)], [flipAt, termH(2)]], 0.7);

  const typeEnd = (at: number, text: string, cps: number) => at + Math.ceil((text.length / cps) * fps);
  const r0 = offerAt + s(0.3);
  const r1 = typeEnd(r0, OFFER[0], 100);
  const r2 = Math.max(cmdAt, typeEnd(r1, OFFER[1], 100));
  const r3 = typeEnd(r2, OFFER[2], 100);
  const r4 = typeEnd(r3, OFFER[3], 110);

  const offerO = (1 - prog(frame, landsAt, 0.4, fps)) * termO;
  const proseO = offerO * mix(1, 0.35, prog(frame, runAt, 0.5, fps));
  const rerun = prog(frame, nextAt, 0.4, fps);
  const flip = prog(frame, flipAt, 0.6, fps);
  const redO = termO * mix(1, 0.4, rerun) * (1 - flip);
  const bannerGlow = prog(frame, greenAt, 0.35, fps) * (1 - prog(frame, greenAt + s(0.6), 0.8, fps));
  const absorbTint = prog(frame, absorbAt, 0.4, fps) * (1 - prog(frame, flipAt, 0.4, fps));
  const showsTint = prog(frame, showsAt, 0.4, fps);

  const underline = (needle: string, at: number) => {
    if (frame < at) return null;
    const col = OFFER[3].indexOf(needle);
    return (
      <div
        key={needle}
        style={{
          position: "absolute",
          left: TEXT_X + col * T_CH,
          top: offerY(3) + T_LH - 5,
          width: needle.length * T_CH * prog(frame, at, 0.45, fps),
          height: 3,
          background: ROLE.candidate,
          opacity: termO * (1 - prog(frame, landsAt, 0.15, fps)),
        }}
      />
    );
  };

  // ── The declaration flies from the offer into the file ──────────────────────────────────────────
  const flightEnd = fileAt + s(0.7);
  const flightP = prog(frame, landsAt, (flightEnd - landsAt) / fps, fps);
  const [fx, fy] = along([TEXT_X + DECL_COL * T_CH, offerY(3)], [F_TEXT_X, F.y + 3 + FILE_TOPS[DECL_ROW]], -90, flightP);
  const flySize = mix(T.size, F.size, flightP);
  const landed = frame >= flightEnd;

  // ── The file card and the pull request sheet behind it ──────────────────────────────────────────
  const fileIn = prog(frame, fileAt, 0.7, fps);
  const fileO = prog(frame, fileAt, 0.4, fps) * mix(1, 0.35, prog(frame, flipAt, 0.6, fps)) * visibility(frame, fps, undefined, clearOut);
  const landGlow = prog(frame, flightEnd, 0.3, fps) * (1 - prog(frame, flightEnd + s(1.0), 0.8, fps));
  const declTint = Math.max(landGlow, absorbTint);

  const prP = prog(frame, prAt, 0.8, fps);
  const prO = (frame >= prAt ? prog(frame, prAt, 0.4, fps) : 0) * (1 - prog(frame, flipAt, 0.5, fps));
  const prInner = prog(frame, prAt + s(0.4), 0.5, fps);
  const pr = {
    x: mix(F.x, PR.x, prP),
    y: mix(F.y, PR.y, prP),
    w: mix(F.w, PR.w, prP),
    h: mix(F_H, PR.h, prP),
  };

  // ── Exit six ────────────────────────────────────────────────────────────────────────────────────
  const chipO = useAppear(matchedAt, clearOut, 0.5);
  const pulse = frame >= sixAt ? Math.sin(Math.PI * Math.min(1, (frame - sixAt) / s(0.8))) : 0;

  // ── The August green, today ─────────────────────────────────────────────────────────────────────
  const augW = AUGUST.length * 30 * MONO_ADVANCE;
  const strike = prog(frame, strikeAt, 0.6, fps);
  const cvReveal = prog(frame, cvAt, 0.8, fps);
  const cvGlow = prog(frame, provesAt, 0.5, fps) * mix(1, 0.35, prog(frame, provesAt + s(1.4), 1.0, fps));
  const qualW = Math.max(...QUALIFICATION.map((l) => l.length)) * 20 * MONO_ADVANCE;

  return (
    <>
      {/* Opening: the topic, and the branch's change in the candidate's colour. */}
      <Text x={960} y={460} size={72} at={intentAt} out={introOut} dur={0.6}>
        intent
      </Text>
      <Pill x={960} y={590} text="branch: loyalty points × 2" color={ROLE.candidate} size={30} at={branchAt} out={introOut} />

      {/* The pull request sheet sits behind the file card. */}
      {prO > 0 && (
        <div
          style={{
            position: "absolute",
            left: pr.x,
            top: pr.y,
            width: pr.w,
            height: pr.h,
            boxSizing: "border-box",
            borderRadius: 20,
            border: `2px solid ${C.dim}`,
            background: `${C.text}06`,
            opacity: prO * 0.85,
          }}
        >
          <div style={{ position: "absolute", left: 30, top: F.y + F_H + 22 - PR.y, opacity: prInner }}>
            <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, color: C.dim, marginBottom: 8 }}>pull request description</div>
            {PR_BLOCK.map((l, i) => (
              <div key={i} style={{ fontFamily: FONT.mono, fontSize: PR.size, lineHeight: `${PR.size * LINE_HEIGHT}px`, whiteSpace: "pre", color: i === 1 ? C.text : C.dim, opacity: 0.6 }}>
                {l}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* The intent file. */}
      {fileO > 0 && (
        <div
          style={{
            position: "absolute",
            left: F.x,
            top: F.y,
            width: F.w,
            height: F_H,
            boxSizing: "border-box",
            borderRadius: 16,
            border: `3px solid ${C.text}`,
            background: `linear-gradient(180deg, ${C.text}1C, ${C.text}08), ${C.bg}`,
            overflow: "hidden",
            opacity: fileO,
            transform: `translateX(${(1 - fileIn) * 1250}px)`,
          }}
        >
          <div
            style={{
              height: F.header,
              boxSizing: "border-box",
              display: "flex",
              alignItems: "center",
              padding: `0 ${F.padX}px`,
              borderBottom: `2px solid ${C.text}55`,
              fontFamily: FONT.mono,
              fontSize: 26,
              color: C.text,
            }}
          >
            .haruspec/intent/&lt;branch&gt;.md
          </div>
          {FILE_ROWS.map((r, i) =>
            "rule" in r ? (
              <div key={i} style={{ position: "absolute", left: F.padX, top: FILE_TOPS[i] + F.rule / 2 - 1, width: F.w - 6 - 2 * F.padX, height: 2, background: `${C.dim}99` }} />
            ) : (
              <div
                key={i}
                style={{
                  position: "absolute",
                  left: F.padX - 8,
                  top: FILE_TOPS[i],
                  padding: "0 8px",
                  borderRadius: 6,
                  fontFamily: FONT.mono,
                  fontSize: F.size,
                  lineHeight: `${F_LH}px`,
                  whiteSpace: "pre",
                  color: r.color ?? C.text,
                  fontWeight: r.weight,
                  opacity: i === DECL_ROW && !landed ? 0 : 1,
                  background: i === DECL_ROW && declTint > 0 ? `${ROLE.candidate}${Math.round(declTint * 0x2c).toString(16).padStart(2, "0")}` : undefined,
                }}
              >
                {r.text}
              </div>
            ),
          )}
        </div>
      )}

      {/* The terminal card. */}
      {termO > 0 && (
        <div
          style={{
            position: "absolute",
            left: T.x,
            top: T.y,
            width: cardW,
            height: cardH,
            boxSizing: "border-box",
            borderRadius: 14,
            border: `2px solid ${C.faint}`,
            background: C.surface,
            opacity: termO,
          }}
        />
      )}
      <Typed
        x={TEXT_X}
        y={PROMPT_Y}
        size={T.size}
        at={frame >= nextAt ? nextAt : termAt + s(0.1)}
        cps={55}
        opacity={termO}
        segs={[{ t: "$ ", color: C.dim }, { t: "haruspec check" }]}
      />
      <TermBanner kind="diverged" w={cardW} opacity={frame >= redAt ? prog(frame, redAt, 0.35, fps) * redO : 0} />
      <TermBanner kind="equivalent" w={cardW} opacity={flip * termO} glow={bannerGlow} />

      {/* The red line, then the offer. */}
      {absorbTint > 0 && (
        <div
          style={{
            position: "absolute",
            left: TEXT_X - 10,
            top: rowY(0),
            width: 56 * T_CH + 20,
            height: T_LH,
            borderRadius: 6,
            background: `${ROLE.candidate}${Math.round(absorbTint * 0x26).toString(16).padStart(2, "0")}`,
            opacity: termO,
          }}
        />
      )}
      <Typed
        x={TEXT_X}
        y={rowY(0)}
        size={T.size}
        at={redAt + s(0.15)}
        opacity={redO}
        segs={[
          { t: "≠ LoyaltyPointsEarned: points: baseline=" },
          { t: "63", color: ROLE.baseline, weight: 700, at: sixtyAt },
          { t: " candidate=", at: hundredAt },
          { t: "126", color: ROLE.candidate, weight: 700, at: hundredAt + s(0.3) },
        ]}
      />

      {proseO > 0 && frame >= runAt && (
        <div
          style={{
            position: "absolute",
            left: TEXT_X - 14,
            top: offerY(2) - 3,
            width: OFFER[3].length * T_CH + 28,
            height: 2 * T_LH + 6,
            boxSizing: "border-box",
            borderLeft: `4px solid ${C.text}`,
            borderRadius: 6,
            background: `${C.text}10`,
            opacity: prog(frame, runAt, 0.4, fps) * offerO,
          }}
        />
      )}
      <Typed x={TEXT_X} y={offerY(0)} size={T.size} at={r0} color={C.dim} opacity={proseO} segs={[{ t: OFFER[0] }]} />
      <Typed x={TEXT_X} y={offerY(1)} size={T.size} at={r1} color={C.dim} opacity={proseO} segs={[{ t: OFFER[1] }]} />
      <Typed x={TEXT_X} y={offerY(2)} size={T.size} at={r2} opacity={offerO} segs={[{ t: OFFER[2] }]} />
      <Typed
        x={TEXT_X}
        y={offerY(3)}
        size={T.size}
        at={r3}
        cps={110}
        opacity={offerO}
        segs={[{ t: OFFER[3].slice(0, DECL_COL) }, { t: DECL, color: frame >= landsAt ? "transparent" : C.text }, { t: "'" }]}
      />
      <Typed x={TEXT_X} y={offerY(4)} size={T.size} at={r4} cps={120} color={C.dim} opacity={proseO} segs={[{ t: OFFER[4] }]} />
      {underline('field: "points"', fieldAt)}
      {underline(".increases()", incAt)}
      {underline('.only(in: "checkout")', onlyAt)}

      {/* After the next check: the divergence, absorbed. */}
      {showsTint > 0 && (
        <div
          style={{
            position: "absolute",
            left: TEXT_X - 10,
            top: rowY(0),
            width: 68 * T_CH + 20,
            height: 2 * T_LH,
            borderRadius: 6,
            background: `${ROLE.equivalent}${Math.round(showsTint * 0x1e).toString(16).padStart(2, "0")}`,
            opacity: termO,
          }}
        />
      )}
      <Mono
        x={TEXT_X}
        y={rowY(0)}
        size={T.size}
        opacity={prog(frame, flipAt + s(0.2), 0.5, fps) * termO}
        segs={[{ t: "  1 divergence(s) — all intended, absorbed by declared intent:" }]}
      />
      <Mono
        x={TEXT_X}
        y={rowY(1)}
        size={T.size}
        opacity={prog(frame, flipAt + s(0.45), 0.5, fps) * termO}
        segs={[
          { t: "    " },
          { t: "✓", color: ROLE.equivalent, weight: 700 },
          { t: " intended LoyaltyPointsEarned: points: baseline=" },
          { t: "63", color: ROLE.baseline, weight: 700 },
          { t: " candidate=" },
          { t: "126", color: ROLE.candidate, weight: 700 },
        ]}
      />

      {/* The declaration in flight. */}
      {frame >= landsAt && !landed && (
        <div
          style={{
            position: "absolute",
            left: fx,
            top: fy,
            fontFamily: FONT.mono,
            fontSize: flySize,
            lineHeight: `${flySize * LINE_HEIGHT}px`,
            whiteSpace: "pre",
            color: C.text,
            textShadow: `0 0 ${16 * Math.sin(Math.PI * flightP)}px ${ROLE.candidate}`,
          }}
        >
          {DECL}
        </div>
      )}

      <Svg>
        <Arrow from={[900, F.y - 8]} to={[900, T.y + termH(1) + 10]} at={absorbAt} out={flipAt} dur={0.5} color={ROLE.candidate} width={3} />
      </Svg>

      {/* Exit six. */}
      {chipO > 0 && (
        <div
          style={{
            position: "absolute",
            left: 960,
            top: 905,
            transform: `translate(-50%, -50%) scale(${(1 + 0.12 * pulse) * mix(0.9, 1, chipO)})`,
            fontFamily: FONT.mono,
            fontSize: 30,
            color: C.dim,
            border: `3px solid ${ROLE.diverged}`,
            background: `${C.dim}22`,
            borderRadius: 999,
            padding: "6px 26px",
            whiteSpace: "pre",
            opacity: chipO,
            boxShadow: pulse > 0 ? `0 0 ${36 * pulse}px ${ROLE.diverged}` : "none",
          }}
        >
          <span style={{ fontWeight: 700, color: C.text }}>6</span> declared, never observed
        </div>
      )}

      {/* The ending: the August green, read today. */}
      {frame >= moreAt && (
        <div style={{ position: "absolute", left: 960 - qualW / 2, top: 600, opacity: 0.15 * prog(frame, moreAt, 1.0, fps) }}>
          {QUALIFICATION.map((l, i) => (
            <div key={i} style={{ fontFamily: FONT.mono, fontSize: 20, lineHeight: `${20 * LINE_HEIGHT}px`, whiteSpace: "pre", color: C.text }}>
              {l}
            </div>
          ))}
        </div>
      )}
      <Text x={960} y={292} size={26} italic color={C.dim} at={augustAt} reveal="fade">
        August 2026
      </Text>
      <Fade x={960} y={360} anchor="center" at={augustAt} rise={0}>
        <div style={{ fontFamily: FONT.mono, fontSize: 30, color: C.text, whiteSpace: "pre", opacity: mix(1, 0.7, strike) }}>{AUGUST}</div>
      </Fade>
      {frame >= strikeAt && <div style={{ position: "absolute", left: 960 - augW / 2 - 10, top: 358, width: (augW + 20) * strike, height: 4, background: ROLE.diverged }} />}
      {frame >= cvAt && (
        <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, clipPath: cvReveal < 1 ? `inset(0 ${1920 - mix(620, 1300, cvReveal)}px 0 0)` : undefined }}>
          <Verdict x={960} y={500} kind="cannotVerify" size={44} at={cvAt} glow={cvGlow} />
        </div>
      )}
    </>
  );
};
