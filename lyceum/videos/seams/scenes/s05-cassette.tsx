import React from "react";
import { useScene, Arrow, Fade, Svg, Text, C, FONT, MONO_ADVANCE, along, mix, prog } from "#kit";
import { ROLE, Verdict, useAppear } from "./shared";

// Seam keys and the qualified-key format are from Cassette.swift and FulfillmentMigrationSpec.swift; the
// values on the tape are illustrative. The report line is SpecTerminalReport.swift's format, with the seam
// name from SpecPlanTests.swift (246–258).

type Pt = [number, number];

/** The cassette, drawn at its own size and scaled where it sits: two tapes (each named beneath), and a
 *  window with two reels. */
const W = 660;
const H = 384;

type CellKey = "mug" | "beans" | "now";

const CELLS: Record<CellKey, { x: number; y: number; w: number; h: number; value: string; tag?: string }> = {
  mug: { x: 36, y: 30, w: 209, h: 76, value: "3", tag: '[sku="MUG"]' },
  beans: { x: 253, y: 30, w: 242, h: 76, value: "0", tag: '[sku="BEANS"]' },
  now: { x: 36, y: 178, w: 384, h: 46, value: "2026-10-02T13:00:00Z" },
};

/** The stock tape past its last recording. */
const BLANK = { x: 503, y: 30, w: 121, h: 76 };

const TAPES = [
  { y: 24, h: 88, label: "Inventory.stock" },
  { y: 172, h: 58, label: "Clock.now" },
];

const WINDOW = { x: 100, y: 286, w: 460, h: 76 };

/** A point of the cassette (in its own coordinates) on the frame, for a cassette centred at `cx`/`cy`
 *  and scaled by `s`. */
const pt = (cx: number, cy: number, s: number, u: number, v: number): Pt => [cx + (u - W / 2) * s, cy + (v - H / 2) * s];

const STAGE_Y = 590;
const COPY_SCALE = 0.92;
const SIDE = { baseline: 520, candidate: 1400 } as const;
const BOX = { y: 190, w: 300, h: 120 };

const Reel: React.FC<{ x: number; y: number; angle: number }> = ({ x, y, angle }) => (
  <g transform={`translate(${x} ${y}) rotate(${angle})`}>
    <circle r={28} fill="none" stroke={ROLE.seam} strokeWidth={3} />
    <circle r={8} fill={ROLE.seam} />
    {[0, 120, 240].map((a) => (
      <line key={a} x1={0} y1={-8} x2={0} y2={-25} stroke={ROLE.seam} strokeWidth={3} transform={`rotate(${a})`} />
    ))}
  </g>
);

const CassetteView: React.FC<{
  cx: number;
  cy: number;
  s: number;
  opacity?: number;
  /** Landing progress per cell, 0…1; a cell not listed is on the tape already. */
  land?: Partial<Record<CellKey, number>>;
  /** Where landing cells drop from, on the frame. */
  from?: Pt;
  angle: number;
  play?: number;
  tagGlow?: number;
  lit?: Partial<Record<CellKey, number>>;
  empty?: number;
}> = ({ cx, cy, s, opacity = 1, land = {}, from, angle, play = 0, tagGlow = 0, lit = {}, empty = 0 }) => {
  if (opacity <= 0) return null;
  return (
    <div style={{ position: "absolute", left: cx - W / 2, top: cy - H / 2, width: W, height: H, transform: `scale(${s})`, opacity }}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          boxSizing: "border-box",
          borderRadius: 28,
          border: `3px solid ${ROLE.seam}`,
          background: `linear-gradient(180deg, ${ROLE.seam}1C, ${ROLE.seam}08), ${C.surface}`,
        }}
      />
      {TAPES.map((t) => (
        <React.Fragment key={t.label}>
          <div style={{ position: "absolute", left: 30, top: t.y, width: 600, height: t.h, boxSizing: "border-box", borderRadius: 10, background: C.sunken, border: `2px solid ${ROLE.seam}55` }} />
          <div style={{ position: "absolute", left: 36, top: t.y + t.h + 4, fontFamily: FONT.mono, fontSize: 28, lineHeight: "32px", color: ROLE.seam, whiteSpace: "nowrap" }}>{t.label}</div>
        </React.Fragment>
      ))}
      <div style={{ position: "absolute", left: WINDOW.x, top: WINDOW.y, width: WINDOW.w, height: WINDOW.h, boxSizing: "border-box", borderRadius: 14, background: C.sunken, border: `2px solid ${ROLE.seam}55` }} />
      <svg width={WINDOW.w} height={WINDOW.h} style={{ position: "absolute", left: WINDOW.x, top: WINDOW.y, overflow: "visible" }}>
        <line x1={70} y1={66} x2={390} y2={66} stroke={`${ROLE.seam}88`} strokeWidth={3} />
        <Reel x={70} y={38} angle={angle} />
        <Reel x={390} y={38} angle={angle} />
        {play > 0 && <polygon points="219,24 219,52 243,38" fill={ROLE.equivalent} opacity={play} />}
      </svg>
      {empty > 0 && (
        <div
          style={{
            position: "absolute",
            left: BLANK.x,
            top: BLANK.y,
            width: BLANK.w,
            height: BLANK.h,
            boxSizing: "border-box",
            borderRadius: 8,
            border: `3px dashed ${ROLE.cannotVerify}`,
            background: `${ROLE.cannotVerify}22`,
            boxShadow: `0 0 ${22 * empty}px ${ROLE.cannotVerify}`,
            opacity: Math.min(1, empty * 1.5),
          }}
        />
      )}
      {empty > 0 && (
        <div
          style={{
            position: "absolute",
            left: BLANK.x + BLANK.w,
            top: BLANK.y + BLANK.h + 4,
            transform: "translateX(-100%)",
            fontFamily: FONT.mono,
            fontSize: 28,
            lineHeight: "32px",
            color: ROLE.cannotVerify,
            whiteSpace: "nowrap",
            opacity: Math.min(1, empty * 1.5),
          }}
        >
          unrecorded
        </div>
      )}
      {(Object.keys(CELLS) as CellKey[]).map((key) => {
        const c = CELLS[key];
        const p = land[key] ?? 1;
        if (p <= 0) return null;
        let dx = 0;
        let dy = 0;
        if (from && p < 1) {
          const target = pt(cx, cy, s, c.x + c.w / 2, c.y + c.h / 2);
          const pos = along(from, target, 0, p);
          dx = (pos[0] - target[0]) / s;
          dy = (pos[1] - target[1]) / s;
        }
        const l = lit[key] ?? 0;
        const edge = l > 0.05 ? ROLE.candidate : ROLE.seam;
        return (
          <div
            key={key}
            style={{
              position: "absolute",
              left: c.x,
              top: c.y,
              width: c.w,
              height: c.h,
              boxSizing: "border-box",
              borderRadius: 8,
              border: `2px solid ${edge}`,
              background: `linear-gradient(${ROLE.seam}26, ${ROLE.seam}26), ${C.sunken}`,
              boxShadow: l > 0 ? `0 0 ${20 * l}px ${ROLE.candidate}` : "none",
              transform: `translate(${dx}px, ${dy}px) scale(${mix(0.6, 1, p)})`,
              opacity: Math.min(1, p * 4),
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <div style={{ fontFamily: FONT.mono, fontSize: 30, lineHeight: "36px", color: C.text, whiteSpace: "nowrap" }}>{c.value}</div>
            {c.tag && (
              <div
                style={{
                  fontFamily: FONT.mono,
                  fontSize: 28,
                  lineHeight: "32px",
                  whiteSpace: "nowrap",
                  color: tagGlow > 0.05 ? ROLE.seam : C.dim,
                  textShadow: tagGlow > 0 ? `0 0 ${16 * tagGlow}px ${ROLE.seam}` : "none",
                }}
              >
                {c.tag}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
};

/** One side of the check: a box with its role; `dot` lights a record dot in its corner. */
const SideBox: React.FC<{ x: number; color: string; label: string; at: number; glow?: number; opacity?: number; dot?: number }> = ({
  x,
  color,
  label,
  at,
  glow = 0,
  opacity = 1,
  dot = 0,
}) => {
  const a = useAppear(at);
  if (a <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x - BOX.w / 2,
        top: BOX.y - BOX.h / 2,
        width: BOX.w,
        height: BOX.h,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${color}`,
        background: `linear-gradient(180deg, ${color}1C, ${color}08)`,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        opacity: a * opacity,
        transform: `scale(${mix(0.94, 1, a)})`,
        boxShadow: glow > 0 ? `0 0 ${40 * glow}px ${color}` : "none",
      }}
    >
      <div style={{ fontFamily: FONT.serif, fontSize: 36, color }}>{label}</div>
      {dot > 0 && (
        <div style={{ position: "absolute", right: 16, top: 16, width: 22, height: 22, borderRadius: 999, background: ROLE.diverged, opacity: dot, boxShadow: `0 0 14px ${ROLE.diverged}` }} />
      )}
    </div>
  );
};

/** The candidate's questions: a chip under its box, which opens to take the answer that travels back. */
const CHIP_Y = 300;
const CHIP_H = 46;
const CHAR = 26 * MONO_ADVANCE;
const chipW = (q: string) => 40 + q.length * CHAR;
const pillW = (a: string) => 20 + a.length * CHAR;
const slotX = (left: number, q: string, a: string) => left + chipW(q) + 10 + CHAR + 10 + pillW(a) / 2;
/** Where a question's line leaves its chip. */
const chipFoot = (left: number, q: string): Pt => [left + chipW(q) / 2, CHIP_Y + CHIP_H / 2];

const Ask: React.FC<{ left: number; q: string; at: number; out?: number; answer: string; answerAt: number; from: Pt; color: string }> = ({
  left,
  q,
  at,
  out,
  answer,
  answerAt,
  from,
  color,
}) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  const travel = frame >= answerAt ? prog(frame, answerAt, 0.55, fps) : 0;
  const open = frame >= answerAt ? prog(frame, answerAt + Math.round(0.25 * fps), 0.3, fps) : 0;
  const extra = 10 + CHAR + 10 + pillW(answer) + 14;
  const p = along(from, [slotX(left, q, answer), CHIP_Y], 0, travel);
  return (
    <>
      <div
        style={{
          position: "absolute",
          left,
          top: CHIP_Y - CHIP_H / 2,
          width: chipW(q) + extra * open,
          height: CHIP_H,
          boxSizing: "border-box",
          borderRadius: 999,
          border: `2.5px solid ${ROLE.candidate}`,
          background: C.surface,
          opacity: o,
          transform: `translateY(${(1 - Math.min(1, o)) * -10}px)`,
        }}
      >
        <div style={{ position: "absolute", left: 17.5, top: 0, fontFamily: FONT.mono, fontSize: 26, lineHeight: `${CHIP_H - 5}px`, color: C.text, whiteSpace: "pre" }}>{q}</div>
        <div style={{ position: "absolute", left: chipW(q) + 7.5, top: 0, fontFamily: FONT.mono, fontSize: 26, lineHeight: `${CHIP_H - 5}px`, color: C.dim, opacity: open }}>→</div>
      </div>
      {travel > 0 && (
        <div
          style={{
            position: "absolute",
            left: p[0],
            top: p[1],
            transform: "translate(-50%, -50%)",
            width: pillW(answer),
            height: 34,
            boxSizing: "border-box",
            borderRadius: 999,
            border: `2.5px solid ${color}`,
            background: `linear-gradient(${color}26, ${color}26), ${C.surface}`,
            fontFamily: FONT.mono,
            fontSize: 26,
            lineHeight: "29px",
            textAlign: "center",
            color: C.text,
            opacity: o * Math.min(1, travel * 4),
          }}
        >
          {answer}
        </div>
      )}
    </>
  );
};

/** The live world: a small cloud that answers what the tape can't. `x`/`y` are its centre. */
const Cloud: React.FC<{ x: number; y: number; at: number }> = ({ x, y, at }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.5);
  if (o <= 0) return null;
  const bob = Math.sin(((frame - at) / fps) * Math.PI * 0.8) * 4;
  const puffs: [number, number, number][] = [
    [-55, 12, 26],
    [-22, -8, 34],
    [20, -14, 36],
    [56, 10, 28],
  ];
  const sw = 3;
  return (
    <div style={{ position: "absolute", left: x - 100, top: y - 60 + bob, width: 200, height: 120, opacity: o, transform: `scale(${mix(0.8, 1, o)})` }}>
      <svg width={200} height={120} viewBox="-100 -60 200 120" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        {puffs.map(([cx, cy, r], i) => (
          <circle key={`edge${i}`} cx={cx} cy={cy} r={r + sw} fill={C.dim} />
        ))}
        <rect x={-55 - sw} y={10 - sw} width={111 + 2 * sw} height={28 + 2 * sw} fill={C.dim} />
        {puffs.map(([cx, cy, r], i) => (
          <circle key={`fill${i}`} cx={cx} cy={cy} r={r} fill={C.surface} />
        ))}
        <rect x={-55} y={10} width={111} height={28} fill={C.surface} />
      </svg>
      <div style={{ position: "absolute", left: 0, top: 46, width: 200, textAlign: "center", fontFamily: FONT.serif, fontStyle: "italic", fontSize: 32, lineHeight: "40px", color: C.text }}>
        live
      </div>
    </div>
  );
};

const Q1 = 'stock(sku: "BEANS")';
const Q2 = 'stock(sku: "MUG")';
const Q4 = "surgeFactor()";
const Q1_LEFT = 982;
const Q2_LEFT = Q1_LEFT + chipW(Q1) + 10 + CHAR + 10 + pillW("0") + 14 + 24;
const Q4_LEFT = 1380;

export const Cassette: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);
  const after = (t: number, dur: number) => (frame >= t ? prog(frame, t, dur, fps) : 0);

  const cassetteAt = cue("a cassette");
  const baselineAt = cue("baseline");
  const runs = cue("runs first");
  const records = cue("records each reading");
  const dropNow = cue("each reading");
  const dropMug = dropNow + s(0.55);
  const dropBeans = cue("order");
  const then = cue("Then");
  const replayed = cue("replayed");
  const bothSides = cue("into both sides");
  const playAt = cue("both sides", { offset: 0.3 });
  const baseNamed = cue("baseline", { after: replayed });
  const candNamed = cue("candidate");
  const identical = cue("answered identically");
  const double = cue("A double");
  const args = cue("its arguments");
  const port = cue("a port");
  const q1 = cue("same questions");
  const q2 = cue("order", { after: q1 });
  const ans2 = cue("gets");
  const whatIf = cue("What if");
  const q4 = cue("past the end");
  const falls = cue("falls back");
  const liveAt = cue("live one");
  const verdictAt = cue("cannot verify");
  const names = cue("names the seam");

  const line1 = q1 + s(0.25);
  const reach1 = line1 + s(0.4);
  const line2 = q2 + s(0.25);
  const reach2 = line2 + s(0.4);
  const line4 = q4 + s(0.25);
  const reach4 = line4 + s(0.5);

  // The reels turn while the tape records or plays: one turn per 1.4 s of running.
  const turn = (wins: [number, number][]) => wins.reduce((a, [a0, a1]) => a + Math.max(0, Math.min(frame, a1) - a0), 0) * (360 / (1.4 * fps));
  const recording: [number, number] = [records, then];
  const playing: [number, number] = [replayed + s(0.9), double];
  const blueAngle = turn([recording, playing]);
  const pinkAngle = turn([recording, playing, [q1, ans2 + s(0.6)], [q4, reach4 + s(0.4)]]);

  const shown = useAppear(cassetteAt);
  const split = after(replayed, 1.0);
  const rec = after(runs, 0.4) * (1 - after(then, 0.5));
  const bump = (t: number) => (frame >= t && frame < t + s(1.2) ? Math.sin(((frame - t) / s(1.2)) * Math.PI) : 0);
  const blueDim = 1 - 0.65 * after(port, 0.6);
  const tagGlow = after(args, 0.5) * (1 - after(whatIf, 0.5));
  const amber = after(reach4, 0.3);
  const pulse = (t: number) => (frame >= t ? 0.5 + 0.5 * Math.sin(((frame - t) / fps) * Math.PI * 2 * 0.8) : 0);
  const play = after(playAt, 0.4);
  const litOut = 1 - after(whatIf, 0.5);

  const blueX = mix(960, SIDE.baseline, split);
  const pinkX = mix(960, SIDE.candidate, split);
  const sc = mix(mix(0.94, 1, shown), COPY_SCALE, split);

  // Targets on the candidate's copy once it has settled.
  const cellTop = (key: CellKey | "blank"): Pt => {
    const c = key === "blank" ? BLANK : CELLS[key];
    return pt(SIDE.candidate, STAGE_Y, COPY_SCALE, c.x + c.w / 2, c.y);
  };
  const above = (p: Pt): Pt => [p[0], p[1] - 6];

  return (
    <>
      <SideBox x={SIDE.baseline} color={ROLE.baseline} label="baseline" at={baselineAt} glow={Math.max(0.6 * rec, bump(baseNamed))} opacity={blueDim} dot={rec * (0.65 + 0.35 * Math.cos(((frame - runs) / fps) * Math.PI * 2))} />
      <SideBox x={SIDE.candidate} color={ROLE.candidate} label="candidate" at={bothSides} glow={bump(candNamed)} />

      {/* Recording: one cassette, centre stage; the readings drop in from the baseline. */}
      {frame < replayed ? (
        <CassetteView
          cx={960}
          cy={STAGE_Y}
          s={sc}
          opacity={shown}
          angle={blueAngle}
          from={[SIDE.baseline, BOX.y + BOX.h / 2]}
          land={{ now: after(dropNow, 0.6), mug: after(dropMug, 0.6), beans: after(dropBeans, 0.6) }}
        />
      ) : (
        <>
          <CassetteView cx={blueX} cy={STAGE_Y} s={sc} opacity={blueDim} angle={blueAngle} play={play} tagGlow={tagGlow} />
          <CassetteView
            cx={pinkX}
            cy={STAGE_Y}
            s={sc}
            angle={pinkAngle}
            play={play}
            tagGlow={tagGlow}
            lit={{ beans: after(reach1, 0.3) * litOut, mug: after(reach2, 0.3) * litOut }}
            empty={amber * (0.7 + 0.3 * pulse(reach4))}
          />
        </>
      )}
      <Text x={960} y={808} size={26} italic color={C.dim} at={cassetteAt + s(0.5)} out={verdictAt} reveal="fade">
        illustrative values
      </Text>

      <Fade x={960} y={BOX.y} anchor="center" at={identical} out={double} rise={6}>
        <div style={{ fontFamily: FONT.serif, fontSize: 30, color: C.text, background: C.faint, borderRadius: 10, padding: "6px 28px", whiteSpace: "nowrap" }}>identical answers</div>
      </Fade>

      {/* The candidate's questions, in its own order: each line runs to the value with its tag. */}
      <Svg>
        <Arrow from={chipFoot(Q1_LEFT, Q1)} to={above(cellTop("beans"))} at={line1} out={whatIf} dur={0.4} color={ROLE.candidate} />
        <Arrow from={chipFoot(Q2_LEFT, Q2)} to={above(cellTop("mug"))} at={line2} out={whatIf} dur={0.4} color={ROLE.candidate} />
        <Arrow from={chipFoot(Q4_LEFT, Q4)} to={above(cellTop("blank"))} at={line4} dur={0.5} color={ROLE.candidate} opacity={1 - amber} />
        <Arrow from={chipFoot(Q4_LEFT, Q4)} to={above(cellTop("blank"))} at={line4} dur={0.5} color={ROLE.cannotVerify} opacity={amber} />
      </Svg>
      <Ask left={Q1_LEFT} q={Q1} at={q1} out={whatIf} answer="0" answerAt={reach1 + s(0.1)} from={cellTop("beans")} color={ROLE.seam} />
      <Ask left={Q2_LEFT} q={Q2} at={q2} out={whatIf} answer="3" answerAt={ans2} from={cellTop("mug")} color={ROLE.seam} />

      {/* Past the end: no track behind the question, so the live world answers. */}
      <Cloud x={1730} y={190} at={falls} />
      <Ask left={Q4_LEFT} q={Q4} at={q4} answer="live" answerAt={liveAt} from={[1730, 228]} color={ROLE.cannotVerify} />

      <Verdict x={960} y={872} kind="cannotVerify" at={verdictAt} />
      <Fade x={960} y={950} anchor="center" at={verdictAt + s(0.5)} rise={10}>
        <div style={{ fontFamily: FONT.mono, fontSize: 28, color: C.text, whiteSpace: "pre" }}>
          <span style={{ color: ROLE.cannotVerify }}>{"⚠︎"}</span>
          {" unrecorded reach: "}
          <span style={{ color: frame >= names ? ROLE.cannotVerify : C.text, textShadow: `0 0 ${18 * pulse(names)}px ${ROLE.cannotVerify}` }}>surgeFactor</span>
          {" (replay fell back to live)"}
        </div>
      </Fade>
    </>
  );
};
