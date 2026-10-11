import React from "react";
import { useScene, Arrow, Box, Fade, Line, Svg, Text, C, FONT, mix, prog, track } from "#kit";
import { ROLE, Verdict, useAppear } from "./shared";

// The boundary, drawn as one world seen through a camera: the overview (old code, new code, a diff
// between them, one world feeding both), a zoom onto the old code where its boundary and three seams
// are drawn, and a pull back so both boundaries show while the world leaks around them.

type Pt = [number, number];

// World layout, at camera scale 1.
const BLUE = { x: 600, y: 520 };
const PINK = { x: 1320, y: 520 };
const BOX = { w: 300, h: 200 };
const FENCE = { w: 540, h: 340, r: 28 };
const DIFF = { x: 960, y: 830, w: 200, h: 100 };
const SKY = { x: 960, y: 200 };
const LANES = [450, 520, 590];
const NAMES = ["collaborators", "values", "threads"];
const FENCE_LEFT = BLUE.x - FENCE.w / 2; // 330
const FENCE_RIGHT = PINK.x + FENCE.w / 2; // 1590
const BOX_TOP = BLUE.y - BOX.h / 2;
const BOX_BOTTOM = BLUE.y + BOX.h / 2;

/** The camera when it zooms onto the old code: the blue box large on the left, the pink box's edge at right. */
const ZOOM = { k: 1.5, tx: -25, ty: -240 };

/** A 0 → 1 → 0 swell lasting `dur` seconds from frame `t`. */
const hump = (frame: number, fps: number, t: number, dur = 1.2) => {
  if (frame < t) return 0;
  const u = (frame - t) / (dur * fps);
  return u >= 1 ? 0 : Math.sin(Math.PI * u);
};

/** A labelled box in a role colour, styled like the cold open's. `x`/`y` are its centre. */
const Panel: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  label: string;
  color: string;
  at: number;
  size?: number;
  mono?: boolean;
  glow?: number;
  opacity?: number;
  /** The label's own opacity, so a box can sit at the frame's edge without a clipped word. */
  labelOpacity?: number;
}> = ({ x, y, w, h, label, color, at, size = 36, mono = false, glow = 0, opacity = 1, labelOpacity = 1 }) => {
  const o = useAppear(at);
  if (o <= 0 || opacity <= 0) return null;
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
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: mono ? FONT.mono : FONT.serif,
        fontSize: size,
        color,
        opacity: o * opacity,
        transform: `scale(${mix(0.92, 1, o)})`,
        boxShadow: glow > 0 ? `0 0 ${36 * glow}px ${color}` : "none",
      }}
    >
      <span style={{ opacity: labelOpacity }}>{label}</span>
    </div>
  );
};

/** The globe: a circle, two meridians and an equator in dim grey. Draw inside `Svg`. */
const Globe: React.FC<{ x: number; y: number; r: number; at: number; out?: number }> = ({ x, y, r, at, out }) => {
  const o = useAppear(at, out);
  if (o <= 0) return null;
  const stroke = { fill: "none", stroke: C.dim, strokeWidth: 3 };
  return (
    <g opacity={o} transform={`translate(${x} ${y}) scale(${mix(0.6, 1, o)})`}>
      <circle r={r} {...stroke} />
      <ellipse rx={r * 0.38} ry={r} {...stroke} strokeWidth={2.5} />
      <ellipse rx={r * 0.76} ry={r} {...stroke} strokeWidth={2.5} />
      <line x1={-r} x2={r} y1={0} y2={0} {...stroke} strokeWidth={2.5} />
    </g>
  );
};

/** The world nobody controls: a soft cloud of overlapping circles. Draw inside `Svg`. */
const PUFFS: [number, number, number][] = [
  [-100, 18, 32],
  [-55, -4, 46],
  [5, -18, 54],
  [65, -2, 46],
  [110, 20, 32],
  [-40, 26, 40],
  [10, 28, 44],
  [60, 26, 40],
];
const Cloud: React.FC<{ x: number; y: number; at: number }> = ({ x, y, at }) => {
  const o = useAppear(at, undefined, 0.8);
  if (o <= 0) return null;
  return (
    <g opacity={o * 0.9} transform={`translate(${x} ${y}) scale(${mix(0.7, 1, o)})`}>
      {PUFFS.map(([dx, dy, r], i) => (
        <circle key={i} cx={dx} cy={dy} r={r} fill={C.faint} />
      ))}
    </g>
  );
};

/** A wavy path from `a` to `b`: a bow plus a ripple that tapers to nothing at both ends. */
function wavy(a: Pt, b: Pt, amp: number, waves: number, bow: number, phase = 0): Pt[] {
  const n = 120;
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len = Math.hypot(dx, dy);
  const nx = -dy / len;
  const ny = dx / len;
  const pts: Pt[] = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const taper = Math.min(1, 5 * t, 5 * (1 - t));
    const off = bow * Math.sin(Math.PI * t) + amp * taper * Math.sin(2 * Math.PI * waves * t + phase);
    pts.push([a[0] + dx * t + nx * off, a[1] + dy * t + ny * off]);
  }
  return pts;
}

/** A grey squiggle that writes on from `a` and ends in an arrowhead at `b`. Draw inside `Svg`. */
const Squiggle: React.FC<{ a: Pt; b: Pt; amp: number; waves: number; bow: number; phase?: number; at: number; dur?: number; swell?: number }> = ({
  a,
  b,
  amp,
  waves,
  bow,
  phase = 0,
  at,
  dur = 1.1,
  swell = 0,
}) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, dur, fps);
  const pts = wavy(a, b, amp, waves, bow, phase);
  const d = "M" + pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" L");
  const tail = pts[pts.length - 6];
  const ang = Math.atan2(b[1] - tail[1], b[0] - tail[0]);
  const head = (u: number, side: number): string => {
    const t = ang + Math.PI + side * 0.45;
    return `${b[0] + Math.cos(t) * u},${b[1] + Math.sin(t) * u}`;
  };
  const headOpacity = Math.max(0, Math.min(1, (p - 0.9) / 0.1));
  const width = 4 + 2 * swell;
  return (
    <g>
      <path d={d} pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - p} fill="none" stroke={C.dim} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" />
      <polygon points={`${b[0]},${b[1]} ${head(20, 1)} ${head(20, -1)}`} fill={C.dim} opacity={headOpacity} />
    </g>
  );
};

/** The cold open's last beat, shrinking away: both sides baseline, and still UNSTABLE. */
const Recall: React.FC<{ from: number; until: number }> = ({ from, until }) => {
  const { frame, fps } = useScene();
  const p = prog(frame, from, Math.max(0.2, (until - from) / fps), fps);
  if (p >= 1) return null;
  const side = (x: number) => (
    <div
      style={{
        position: "absolute",
        left: x - 150,
        top: 360,
        width: 300,
        height: 150,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${ROLE.baseline}`,
        background: `linear-gradient(180deg, ${ROLE.baseline}1C, ${ROLE.baseline}08)`,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 10,
      }}
    >
      <div style={{ fontFamily: FONT.serif, fontSize: 34, color: ROLE.baseline }}>baseline</div>
      <div style={{ fontFamily: FONT.mono, fontSize: 26, color: C.dim }}>MintingSubject</div>
    </div>
  );
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, opacity: 1 - p, transform: `scale(${mix(1, 0.3, p)})`, transformOrigin: "960px 540px" }}>
      {side(760)}
      {side(1160)}
      <Verdict x={960} y={600} kind="unstable" size={36} />
    </div>
  );
};

/** The diff box's alarm: a question mark in amber that pops, then keeps a slow pulse. */
const Question: React.FC<{ x: number; y: number; at: number }> = ({ x, y, at }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.3);
  if (o <= 0) return null;
  const pop = hump(frame, fps, at, 0.5);
  const glow = 0.5 + 0.5 * Math.sin(((frame - at) / fps) * Math.PI * 2 * 0.8);
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) scale(${mix(0.6, 1, o) + 0.3 * pop})`,
        fontFamily: FONT.serif,
        fontWeight: 700,
        fontSize: 96,
        lineHeight: 1,
        color: ROLE.cannotVerify,
        textShadow: `0 0 ${12 + 26 * glow}px ${ROLE.cannotVerify}`,
        opacity: o,
      }}
    >
      ?
    </div>
  );
};

export const Boundary: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const drives = cue("Haruspec drives");
  const oldCode = cue("the old code");
  const newCode = cue("the new code");
  const diffs = cue("diffs what they did");
  const difference = cue("A difference only means");
  const bothSides = cue("both sides were handed");
  const sameWorld = cue("the same world");
  const so = cue("So draw a line");
  const line = cue("line around the subject");
  const subject = cue("the subject");
  const seam = cue("is a seam");
  const named = [cue("collaborators"), cue("values"), cue("threads")];
  const controls = cue("controls each one");
  const soBoth = cue("so both sides");
  const identical = cue("identical inputs");
  const when = cue("When the world leaks");
  const leaks = cue("leaks in");
  const twoSides = cue("the two sides");
  const differentWorlds = cue("different worlds");
  const mightBe = cue("a difference might be");
  const notYours = cue("not your change");

  // The camera: overview, zoom onto the old code at "So draw a line", back out at "so both sides".
  const z = track(frame, fps, [[0, 0], [so, 1], [soBoth, 0]], 1.3);
  const k = mix(1, ZOOM.k, z);
  const tx = mix(0, ZOOM.tx, z);
  const ty = mix(0, ZOOM.ty, z);
  const diffDim = 1 - 0.9 * z;

  const sidesGlow = hump(frame, fps, bothSides, 1.4);
  const diffGlow = Math.max(hump(frame, fps, difference, 1.4), hump(frame, fps, mightBe, 1.2));
  const alarm = frame >= notYours ? prog(frame, notYours, 0.3, fps) : 0;
  const worldsSwell = hump(frame, fps, differentWorlds, 1.2);

  const blueIn = BLUE.x - BOX.w / 2 - 8;
  const pinkIn = PINK.x + BOX.w / 2 + 8;

  return (
    <>
      <Recall from={s(0.3)} until={drives} />

      <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, transformOrigin: "0 0", transform: `translate(${tx}px, ${ty}px) scale(${k})` }}>
        {/* Under the boxes: boundaries, the globe and its feed, the cloud, the diff arrows. */}
        <Svg>
          <Box x={BLUE.x} y={BLUE.y} w={FENCE.w} h={FENCE.h} r={FENCE.r} at={line} dur={1.0} color={C.text} width={3} dashed />
          <Box x={BLUE.x} y={BLUE.y} w={FENCE.w} h={FENCE.h} r={FENCE.r} at={seam} out={seam + s(1.4)} dur={0.6} color={ROLE.seam} width={4} dashed />
          <Box x={PINK.x} y={PINK.y} w={FENCE.w} h={FENCE.h} r={FENCE.r} at={soBoth + s(0.4)} dur={0.9} color={C.text} width={3} dashed />

          <Globe x={SKY.x} y={SKY.y} r={46} at={sameWorld} out={so} />
          <Line from={[SKY.x - 50, SKY.y]} to={[BLUE.x, SKY.y]} at={sameWorld + s(0.3)} out={so} dur={0.5} color={C.dim} width={3} />
          <Line from={[SKY.x + 50, SKY.y]} to={[PINK.x, SKY.y]} at={sameWorld + s(0.3)} out={so} dur={0.5} color={C.dim} width={3} />
          <Arrow from={[BLUE.x, SKY.y]} to={[BLUE.x, BOX_TOP - 10]} at={sameWorld + s(0.75)} out={so} dur={0.5} color={C.dim} />
          <Arrow from={[PINK.x, SKY.y]} to={[PINK.x, BOX_TOP - 10]} at={sameWorld + s(0.75)} out={so} dur={0.5} color={C.dim} />

          <Cloud x={SKY.x} y={SKY.y + 10} at={when + s(0.3)} />

          <Arrow from={[BLUE.x + 40, BOX_BOTTOM + 8]} to={[DIFF.x - DIFF.w / 2 - 10, DIFF.y - 10]} bend={40} at={diffs} dur={0.6} color={ROLE.baseline} opacity={diffDim} />
          <Arrow from={[PINK.x - 40, BOX_BOTTOM + 8]} to={[DIFF.x + DIFF.w / 2 + 10, DIFF.y - 10]} bend={-40} at={diffs + s(0.2)} dur={0.6} color={ROLE.candidate} opacity={diffDim} />
        </Svg>

        <Panel x={BLUE.x} y={BLUE.y} w={BOX.w} h={BOX.h} label="old code" color={ROLE.baseline} at={oldCode} glow={sidesGlow} />
        <Panel x={PINK.x} y={PINK.y} w={BOX.w} h={BOX.h} label="new code" color={ROLE.candidate} at={newCode} glow={sidesGlow} opacity={mix(1, 0.6, z)} labelOpacity={Math.max(0, 1 - 2 * z)} />
        <Panel x={DIFF.x} y={DIFF.y} w={DIFF.w} h={DIFF.h} label="diff" mono size={34} color={C.text} at={diffs + s(0.3)} glow={diffGlow} opacity={diffDim * (1 - alarm)} />
        <Panel x={DIFF.x} y={DIFF.y} w={DIFF.w} h={DIFF.h} label="diff" mono size={34} color={ROLE.cannotVerify} at={notYours} glow={0.4 + 0.6 * hump(frame, fps, notYours, 0.8)} />

        {/* Over the boxes: the seams and the leaks. */}
        <Svg>
          {LANES.map((y, i) => (
            <React.Fragment key={i}>
              <Arrow from={[100, y]} to={[blueIn, y]} at={named[i]} out={controls + s(0.5)} dur={0.8} color={C.dim} width={4} />
              <Arrow from={[100, y]} to={[blueIn, y]} at={controls + s(0.1 * i)} dur={0.6} color={ROLE.seam} width={4} />
              <Box x={FENCE_LEFT} y={y} w={12} h={38} r={4} at={named[i] + s(0.45)} dur={0.3} color={ROLE.seam} fill={ROLE.seam} />

              <Arrow from={[1820, y]} to={[pinkIn, y]} at={soBoth + s(0.7 + 0.15 * i)} dur={0.6} color={ROLE.seam} width={4} />
              <Box x={FENCE_RIGHT} y={y} w={12} h={38} r={4} at={soBoth + s(1.0 + 0.15 * i)} dur={0.3} color={ROLE.seam} fill={ROLE.seam} />
            </React.Fragment>
          ))}

          <Squiggle a={[905, 262]} b={[690, BOX_TOP + 22]} amp={13} waves={3.5} bow={-30} at={leaks} swell={worldsSwell} />
          <Squiggle a={[1015, 262]} b={[1235, BOX_TOP + 22]} amp={22} waves={2} bow={45} phase={1.3} at={twoSides} swell={worldsSwell} />
        </Svg>

        {/* Labels. */}
        <Text x={SKY.x} y={SKY.y + 92} size={30} italic color={C.text} at={sameWorld + s(0.3)} out={so} reveal="fade">
          the same world
        </Text>
        <Text x={FENCE_LEFT} y={BLUE.y - FENCE.h / 2 - 32} size={30} italic anchor="left" color={C.text} at={subject} dur={0.8}>
          the subject's boundary
        </Text>
        {LANES.map((y, i) => (
          <React.Fragment key={i}>
            <Text x={100} y={y - 28} size={28} anchor="left" color={C.text} at={named[i]} dur={0.5}>
              {NAMES[i]}
            </Text>
            <Text x={FENCE_LEFT + 14} y={y - 25} size={26} anchor="left" color={ROLE.seam} at={named[i] + s(0.5)} reveal="fade">
              seam
            </Text>
          </React.Fragment>
        ))}

        <Fade x={SKY.x} y={SKY.y + 10} anchor="center" at={identical} out={when} rise={8}>
          <div style={{ fontFamily: FONT.serif, fontSize: 32, color: C.text, background: `${ROLE.seam}26`, border: `2px solid ${ROLE.seam}88`, borderRadius: 12, padding: "8px 30px", whiteSpace: "nowrap" }}>
            identical inputs
          </div>
        </Fade>

        <Text x={SKY.x} y={SKY.y + 14} size={32} italic color={C.dim} at={when + s(0.6)} reveal="fade">
          the world
        </Text>

        <Question x={DIFF.x} y={DIFF.y - 118} at={notYours} />
      </div>
    </>
  );
};
