import React from "react";
import { useScene, Fade, Text, C, FONT, MONO_ADVANCE, mix, prog, lin, visibility } from "#kit";
import { ROLE, VERDICT, useAppear } from "./shared";

// The cold open's MintingSubject, fixed. The card is simplified from the fixture (the brief's three lines,
// with the init's parameter list broken over two lines to fit); the `.provides` line is the real one
// from scene 04. The cold open's two identifiers are illustrative, as there.

const COL = { baseline: 1290, candidate: 1640 } as const;
const SIZE = 26;
const LH = SIZE * 1.55;
const ADV = SIZE * MONO_ADVANCE;
const CARD = { left: 80, top: 150, w: 1000 } as const;
const MINTED = "00000000-…-000000000001";

const mono: React.CSSProperties = { fontFamily: FONT.mono, fontSize: SIZE, lineHeight: `${LH}px`, whiteSpace: "pre", color: C.text };

/** One character that crossfades into another, in place. */
const Swap: React.FC<{ a: string; b: string; p: number }> = ({ a, b, p }) => (
  <span style={{ position: "relative", display: "inline-block" }}>
    <span style={{ opacity: 1 - p }}>{a}</span>
    <span style={{ position: "absolute", left: 0, top: 0, opacity: p }}>{b}</span>
  </span>
);

/** The subject, simplified: the init takes the identifier's source from `injectAt`, and the payload
 *  draws from it. `UUID()` is ringed violet from `sourceAt` until the swap. */
const SubjectCard: React.FC<{ at: number; out: number; sourceAt: number; injectAt: number }> = ({ at, out, sourceAt, injectAt }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out);
  if (o <= 0) return null;
  const grow = prog(frame, injectAt, 0.4, fps);
  const write = lin(frame, injectAt + Math.round(0.2 * fps), 0.8, fps);
  const swap = prog(frame, injectAt + Math.round(0.7 * fps), 0.5, fps);
  const ring = frame >= sourceAt ? prog(frame, sourceAt, 0.4, fps) * (1 - swap) : 0;
  const pulse = frame >= sourceAt ? 0.5 + 0.5 * Math.sin(((frame - sourceAt) / fps) * Math.PI * 1.6) : 0;
  const header = 52;
  const h = header + (3 + grow) * LH + 36;
  return (
    <div
      style={{
        position: "absolute",
        left: CARD.left,
        top: CARD.top,
        width: CARD.w,
        height: h,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${C.text}`,
        background: `linear-gradient(180deg, ${C.text}1C, ${C.text}08)`,
        opacity: o,
        transform: `scale(${mix(0.94, 1, o)})`,
        overflow: "hidden",
      }}
    >
      <div
        style={{
          height: header,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "0 24px",
          borderBottom: `2px solid ${C.text}55`,
        }}
      >
        <span style={{ fontFamily: FONT.mono, fontSize: 26, color: C.text }}>MintingSubject</span>
        <span style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, color: C.dim }}>simplified</span>
      </div>
      <div style={{ padding: "18px 24px" }}>
        <div style={mono}>
          init(center: NotificationCenter
          <Swap a=")" b="," p={grow} />
        </div>
        <div style={{ ...mono, height: LH * grow, overflow: "hidden" }}>
          {"     "}
          <span style={{ display: "inline-block", clipPath: `inset(0 ${(1 - write) * 100}% 0 0)` }}>
            <span style={{ color: ROLE.seam }}>newOrderID: @escaping () -&gt; UUID</span>)
          </span>
        </div>
        <div style={{ ...mono, color: C.dim }}>…</div>
        <div style={mono}>
          {'userInfo: ["value": 42, "orderID": '}
          <span style={{ position: "relative", display: "inline-block", width: mix(6, 12, swap) * ADV }}>
            <span style={{ opacity: 1 - swap }}>UUID()</span>
            <span style={{ position: "absolute", left: 0, top: 0, opacity: swap, color: ROLE.seam }}>newOrderID()</span>
            {ring > 0 && (
              <span
                style={{
                  position: "absolute",
                  left: -6,
                  top: 2,
                  width: 6 * ADV + 12,
                  height: LH - 4,
                  boxSizing: "border-box",
                  borderRadius: 8,
                  border: `2.5px solid ${ROLE.unstable}`,
                  opacity: ring,
                  boxShadow: `0 0 ${22 * pulse}px ${ROLE.unstable}`,
                }}
              />
            )}
          </span>
          .uuidString]
        </div>
      </div>
    </div>
  );
};

/** The spec's line that hands both sides the same identifier source; it slides out from under the card. */
const Provides: React.FC<{ at: number; out: number }> = ({ at, out }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, 0.6, fps);
  const o = p * visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: CARD.left,
        top: mix(390, 425, p),
        boxSizing: "border-box",
        padding: "14px 20px",
        borderRadius: 12,
        border: `2.5px solid ${C.dim}`,
        background: C.surface,
        opacity: o,
        ...mono,
      }}
    >
      .provides((() -&gt; UUID).self) {"{ _ in "}
      <span style={{ color: ROLE.seam }}>Minted.identifiers()</span>
      {" }"}
    </div>
  );
};

/** One side of the check: a box with its role and the subject's type. `glowAt` rings it once. */
const Side: React.FC<{ x: number; role: "baseline" | "candidate"; at: number; out: number; glowAt?: number }> = ({ x, role, at, out, glowAt }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out);
  if (o <= 0) return null;
  const color = role === "baseline" ? ROLE.baseline : ROLE.candidate;
  const t = glowAt === undefined ? -1 : (frame - glowAt) / fps;
  const glow = t >= 0 && t < 1.6 ? Math.sin((t / 1.6) * Math.PI) : 0;
  return (
    <div
      style={{
        position: "absolute",
        left: x - 150,
        top: 270,
        width: 300,
        height: 150,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${color}`,
        background: `linear-gradient(180deg, ${color}1C, ${color}08)`,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 10,
        opacity: o,
        boxShadow: glow > 0 ? `0 0 ${40 * glow}px ${color}` : "none",
      }}
    >
      <div style={{ fontFamily: FONT.serif, fontSize: 34, color }}>{role}</div>
      <div style={{ fontFamily: FONT.mono, fontSize: 26, color: C.dim }}>MintingSubject</div>
    </div>
  );
};

/** The payload a side posts: `value 42` and its identifier, which crossfades from a made-up one (violet)
 *  to the spec's (teal) at `swapAt`, widening and gliding from under its box to `to`. */
const Payload: React.FC<{ from: number; to: number; color: string; id: string; at: number; out: number; swapAt: number; glowAt: number }> = ({
  from,
  to,
  color,
  id,
  at,
  out,
  swapAt,
  glowAt,
}) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out);
  if (o <= 0) return null;
  const s = prog(frame, swapAt, 0.6, fps);
  const pad = 10;
  const w = mix(id.length, MINTED.length, s) * ADV + 2 * pad + 5;
  const cx = mix(from, to, s);
  const t = (frame - glowAt) / fps;
  const glow = t >= 0 && t < 1.4 ? Math.sin((t / 1.4) * Math.PI) : 0;
  const row: React.CSSProperties = { fontFamily: FONT.mono, fontSize: 26, lineHeight: "38px", whiteSpace: "pre", color: C.text, height: 38 };
  return (
    <div
      style={{
        position: "absolute",
        left: cx - w / 2,
        top: 458,
        width: w,
        boxSizing: "border-box",
        border: `2.5px solid ${color}`,
        borderRadius: 14,
        padding: `6px ${pad}px`,
        background: C.surface,
        opacity: o,
      }}
    >
      <div style={row}>value 42</div>
      <div style={row}>orderID</div>
      <div style={{ ...row, position: "relative" }}>
        <span style={{ position: "absolute", left: 0, top: 0, color: ROLE.unstable, opacity: 1 - s }}>{id}</span>
        <span style={{ position: "absolute", left: 0, top: 0, color: ROLE.seam, opacity: s, textShadow: glow > 0 ? `0 0 ${18 * glow}px ${ROLE.seam}` : "none" }}>
          {MINTED}
        </span>
      </div>
    </div>
  );
};

/** The verdict across both box bottoms: violet UNSTABLE drops in at `at`, then flips to green EQUIVALENT. */
const Banner: React.FC<{ at: number; flipAt: number; out: number }> = ({ at, flipAt, out }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const drop = prog(frame, at, 0.5, fps);
  const flip = prog(frame, flipAt, 0.5, fps);
  const fade = visibility(frame, fps, undefined, out);
  const bar = (kind: "unstable" | "equivalent", opacity: number) => (
    <div
      style={{
        position: "absolute",
        left: 1120,
        top: mix(330, 395, drop),
        width: 690,
        height: 50,
        borderRadius: 12,
        background: `${VERDICT[kind].color}E6`,
        color: C.bg,
        fontFamily: FONT.mono,
        fontWeight: 700,
        fontSize: 32,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        opacity,
        transform: kind === "equivalent" ? `scale(${mix(0.96, 1, flip)})` : undefined,
      }}
    >
      {VERDICT[kind].icon} {VERDICT[kind].text}
    </div>
  );
  return (
    <>
      {bar("unstable", drop * (1 - flip) * fade)}
      {flip > 0 && bar("equivalent", flip * fade)}
    </>
  );
};

/** One line of the discipline: `left → right`, the arrow and right-hand phrase in teal, written on in turn. */
const Rule: React.FC<{ y: number; left: string; right: string; at: number; pulseAt: number }> = ({ y, left, right, at, pulseAt }) => {
  const { frame, fps } = useScene();
  const s = (sec: number) => Math.round(sec * fps);
  const t = (frame - pulseAt) / fps;
  const glow = t >= 0 && t < 1.4 ? Math.sin((t / 1.4) * Math.PI) : 0;
  return (
    <>
      <Text x={860} y={y} size={40} anchor="right" at={at} dur={0.6}>
        {left}
      </Text>
      <Text x={900} y={y} size={40} color={ROLE.seam} at={at + s(0.3)} dur={0.3}>
        →
      </Text>
      <Text
        x={940}
        y={y}
        size={40}
        anchor="left"
        color={ROLE.seam}
        at={at + s(0.45)}
        dur={0.7}
        style={{ textShadow: glow > 0 ? `0 0 ${20 * glow}px ${ROLE.seam}` : "none" }}
      >
        {right}
      </Text>
    </>
  );
};

/** A pointer to another video in the set. `x`/`y` are its centre. */
const EndCard: React.FC<{ x: number; y: number; title: string; sub: string; at: number }> = ({ x, y, title, sub, at }) => (
  <Fade x={x} y={y} anchor="center" at={at} rise={20}>
    <div
      style={{
        width: 520,
        height: 140,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `2.5px solid ${C.dim}`,
        background: C.surface,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 8,
      }}
    >
      <div style={{ fontFamily: FONT.serif, fontSize: 44, color: C.text }}>{title}</div>
      <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 30, color: C.dim }}>{sub}</div>
    </div>
  </Fade>
);

export const Recap: React.FC = () => {
  const { fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const disagree = cue("couldn't agree");
  const source = cue("identifier's source");
  const inject = cue("through the initializer");
  const provide = cue("provide sequential identifiers");
  const minted = cue("sequential identifiers");
  const same = cue("both sides draw");
  const reproduces = cue("The baseline reproduces");
  const equivalent = cue("reads equivalent");
  const discipline = cue("That's the discipline");
  const collaborators = cue("Collaborators");
  const values = cue("values", { after: collaborators });
  const threads = cue("threads", { after: values });
  const controls = cue("the spec controls them");
  const specs = cue("watch specs");
  const verdicts = cue("watch verdicts");

  return (
    <>
      {/* The cold open, recalled: the subject against itself, still unstable. */}
      <SubjectCard at={0} out={discipline} sourceAt={source} injectAt={inject} />
      <Provides at={provide} out={discipline} />
      <Text x={CARD.left + 20} y={532} size={26} italic color={C.dim} anchor="left" at={provide + s(0.4)} out={discipline} reveal="fade">
        in the spec
      </Text>

      <Side x={COL.baseline} role="baseline" at={0} out={discipline} glowAt={reproduces} />
      <Side x={COL.candidate} role="candidate" at={s(0.2)} out={discipline} />
      <Payload from={COL.baseline} to={1242} color={ROLE.baseline} id="3F2C9A1E-…" at={s(0.3)} out={discipline} swapAt={minted} glowAt={same} />
      <Payload from={COL.candidate} to={1648} color={ROLE.candidate} id="9B07D4C2-…" at={s(0.5)} out={discipline} swapAt={minted + s(0.15)} glowAt={same} />
      <Banner at={disagree} flipAt={equivalent} out={discipline} />

      {/* The discipline in three lines. */}
      <Text x={960} y={260} size={44} italic color={C.dim} at={discipline + s(0.5)} reveal="fade">
        the discipline
      </Text>
      <Rule y={380} left="collaborators" right="the initializer" at={collaborators} pulseAt={controls} />
      <Rule y={465} left="values" right="provided by the spec" at={values} pulseAt={controls} />
      <Rule y={550} left="threads" right="a stamped queue" at={threads} pulseAt={controls} />

      {/* Where to go next. */}
      <EndCard x={660} y={770} title="specs" sub="write the spec" at={specs} />
      <EndCard x={1260} y={770} title="verdicts" sub="read the verdict" at={verdicts} />
      <Text x={960} y={900} size={28} font="mono" color={C.dim} at={verdicts + s(0.6)} reveal="fade">
        docs/seams.md
      </Text>
    </>
  );
};
