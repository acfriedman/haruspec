import React from "react";
import { useScene, Svg, Line, Text, C, FONT, mix, prog, lin, track } from "#kit";
import { ROLE, VERDICT } from "./shared";

// The verdict text, icons, colours and exit codes are the engine's own (shared.tsx, from
// Core/DiffReport.swift and CLI/main.swift). The balance is illustrative: a metaphor, not a cost model.

type Kind = keyof typeof VERDICT;
const KINDS: Kind[] = ["equivalent", "diverged", "cannotVerify", "unstable"];

/** Four equal 440 px slots between the 80 px margins. Every pill takes the same width, set by the
 *  widest ("⚠️ CANNOT-VERIFY"), so the gaps between them stay equal. */
const SLOT_X = [300, 740, 1180, 1620];
const PILL_W = 392;
const PILL_H = 72;
const PILL_SIZE = 34;
/** The row's centre line, before and after it rises to make room for the balance. */
const ROW_Y = 420;
const ROW_UP = 240;
/** Offsets under a pill's centre: its exit code, then the threads chips hang from. */
const EXIT_DY = 70;
const CHIP_DY = [92, 170];
const THREAD = 30;

/** The balance: pivot, half-beam, string drop to the pan rim, pan half-width, floor line. */
const PIVOT = { x: 960, y: 720 };
const HALF = 330;
const DROP = 95;
const PAN = 100;
const FLOOR = 905;
/** Where the cannot-verify pill settles, above the balance, and its caption beneath it. */
const HERO = { x: 960, y: 540 };

/** Ease-out with an overshoot (manim's back-out): passes 1, then settles back onto it. */
const backOut = (t: number, s = 2) => 1 + (s + 1) * Math.pow(t - 1, 3) + s * Math.pow(t - 1, 2);

/** A verdict pill that can sit as a dim outline (`fill` 0) and fill to its colour (`fill` 1), in the
 *  shared `Verdict` look but a fixed width. `x`/`y` are its centre; `appear` is its entrance,
 *  `opacity` a dimmer on top of it. */
const VerdictSlot: React.FC<{
  x: number;
  y: number;
  kind: Kind;
  appear: number;
  fill: number;
  opacity?: number;
  glow?: number;
  scale?: number;
  /** 0…1: greys the filled icon, whose colour would otherwise outshine a dimmed pill. */
  mute?: number;
}> = ({ x, y, kind, appear, fill, opacity = 1, glow = 0, scale = 1, mute = 0 }) => {
  if (appear <= 0 || opacity <= 0) return null;
  const { text, icon, color } = VERDICT[kind];
  const face = (border: string, ink: string, bg: string, o: number, muted: boolean) => (
    <div
      style={{
        position: "absolute",
        inset: 0,
        boxSizing: "border-box",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 14,
        borderRadius: 999,
        border: `3px solid ${border}`,
        background: bg,
        color: ink,
        opacity: o,
        fontFamily: FONT.mono,
        fontWeight: 600,
        fontSize: PILL_SIZE,
        whiteSpace: "nowrap",
      }}
    >
      <span style={muted ? { filter: "grayscale(1)", opacity: 0.4 } : { filter: `grayscale(${mute})`, opacity: mix(1, 0.5, mute) }}>{icon}</span>
      <span>{text}</span>
    </div>
  );
  return (
    <div
      style={{
        position: "absolute",
        left: x - PILL_W / 2,
        top: y - PILL_H / 2,
        width: PILL_W,
        height: PILL_H,
        borderRadius: 999,
        opacity: appear * opacity,
        transform: `scale(${scale * mix(0.88, 1, appear)})`,
        boxShadow: glow > 0 ? `0 0 ${44 * glow}px ${color}` : "none",
      }}
    >
      {fill < 1 && face(C.faint, C.dim, "transparent", 1 - fill, true)}
      {fill > 0 && face(color, color, `${color}1E`, fill, false)}
    </div>
  );
};

/** A line of text centred on `x`/`y` whose opacity the caller drives frame by frame. */
const Label: React.FC<{ x: number; y: number; text: string; color: string; opacity: number; size?: number }> = ({ x, y, text, color, opacity, size = 26 }) =>
  opacity <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translate(-50%, -50%)",
        fontFamily: FONT.mono,
        fontSize: size,
        color,
        opacity,
        whiteSpace: "nowrap",
      }}
    >
      {text}
    </div>
  );

/** A small tag hanging under a pill: a short thread drops from `top`, then the chip swings in on it
 *  and settles. */
const Chip: React.FC<{ x: number; top: number; text: string; color: string; at: number; opacity: number }> = ({ x, top, text, color, at, opacity }) => {
  const { frame, fps } = useScene();
  if (frame < at || opacity <= 0) return null;
  const thread = prog(frame, at, 0.3, fps);
  const hang = at + Math.round(0.15 * fps);
  const p = prog(frame, hang, 0.4, fps);
  const swing = -9 * (1 - backOut(lin(frame, hang, 0.7, fps), 2.6));
  return (
    <div style={{ position: "absolute", left: 0, top: 0, opacity }}>
      <div style={{ position: "absolute", left: x - 1, top, width: 2, height: THREAD * thread, background: `${color}99` }} />
      <div
        style={{
          position: "absolute",
          left: x,
          top: top + THREAD,
          transform: `translate(-50%, ${(1 - p) * -10}px) rotate(${swing}deg)`,
          transformOrigin: "50% 0",
          opacity: p,
          fontFamily: FONT.mono,
          fontSize: 26,
          color,
          border: `2.5px solid ${color}`,
          borderRadius: 999,
          padding: "3px 18px",
          background: `${color}1E`,
          whiteSpace: "nowrap",
        }}
      >
        {text}
      </div>
    </div>
  );
};

/** An SVG path that draws on from `at` over `dur` seconds, then (with `fill`) floods in. */
const DrawPath: React.FC<{ d: string; at: number; dur: number; color: string; width?: number; fill?: string }> = ({ d, at, dur, color, width = 4, fill }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, dur, fps);
  const f = fill ? prog(frame, at + Math.round(dur * 0.7 * fps), 0.4, fps) : 0;
  return (
    <path
      d={d}
      pathLength={1}
      strokeDasharray="1 1"
      strokeDashoffset={1 - p}
      stroke={color}
      strokeWidth={width}
      strokeLinejoin="round"
      strokeLinecap="round"
      fill={fill ?? "none"}
      fillOpacity={f}
    />
  );
};

export const FourVerdicts: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const one = cue("one");
  const four = cue("four verdicts");
  const equivalent = cue("Equivalent");
  const diverged = cue("Diverged", { after: equivalent });
  const cannot = cue("Cannot verify", { after: diverged });
  const unstable = cue("Unstable", { after: cannot });
  const gap = cue("names the gap", { after: cannot });
  const fresh = cue("a fresh identifier", { after: unstable });
  const clock = cue("a clock reading", { after: fresh });
  const whyFour = cue("Why four");
  const worst = cue("the worst thing");
  const alarm = cue("false alarm", { after: worst });
  const hour = cue("an hour", { after: alarm });
  const green = cue("false green", { after: hour });
  const ships = cue("ships a bug", { after: green });
  const why = cue("That's why", { after: ships });
  const rather = cue("rather say", { after: why });

  // "One of four": diverged (the last scene's verdict) comes first, then the rest of the row.
  const appearAt = [four, one, four + s(0.12), four + s(0.24)];
  const fills = [equivalent, diverged, cannot, unstable];
  const releases = [diverged, cannot, unstable, whyFour];

  // On "the worst thing" the row dims and rises out of the balance's way.
  const rowY = track(frame, fps, [[0, ROW_Y], [worst, ROW_UP]], 0.9);
  const dimmed = prog(frame, worst, 0.6, fps);
  const rowO = mix(1, 0.25, dimmed);

  // The balance: level as it writes on, dips left a little for the hour, then drops hard right.
  const tilt = mix(mix(0, -3, prog(frame, hour, 0.7, fps)), 9, backOut(lin(frame, ships, 0.5, fps)));
  const rad = (tilt * Math.PI) / 180;
  const dx = HALF * Math.cos(rad);
  const dy = HALF * Math.sin(rad);
  const left = { x: PIVOT.x - dx, y: PIVOT.y - dy };
  const right = { x: PIVOT.x + dx, y: PIVOT.y + dy };
  const rimL = left.y + DROP;
  const rimR = right.y + DROP;
  const bowl = (ex: number, rim: number) => `M ${ex - PAN} ${rim} Q ${ex} ${rim + 48} ${ex + PAN} ${rim} Z`;
  const beamAt = worst + s(0.35);
  const stringAt = worst + s(0.85);
  const panAt = worst + s(1.05);
  const balO = mix(1, 0.6, prog(frame, why, 0.8, fps));

  // "That's why": cannot-verify lifts out of its dimmed slot to sit above the balance.
  const lift = prog(frame, why, 0.9, fps);
  const breathe = (from: number, rate = 1.2) => 0.75 + 0.25 * Math.sin(((frame - from) / fps) * Math.PI * rate);

  return (
    <>
      {KINDS.map((kind, i) => {
        const x = SLOT_X[i];
        const appear = frame < appearAt[i] ? 0 : prog(frame, appearAt[i], 0.45, fps);
        const fill = prog(frame, fills[i], 0.4, fps);
        // The verdict being described glows, breathing, until the next one takes over.
        const active = fill * (1 - prog(frame, releases[i], 0.5, fps));
        const pop = Math.sin(Math.PI * lin(frame, fills[i], 0.35, fps));
        const count = Math.sin(Math.PI * lin(frame, whyFour + s(0.1 * i), 0.4, fps));
        return (
          <React.Fragment key={kind}>
            <VerdictSlot
              x={x}
              y={rowY}
              kind={kind}
              appear={appear}
              fill={fill}
              opacity={rowO}
              glow={active * breathe(fills[i]) * 0.8}
              scale={1 + 0.07 * pop + 0.06 * count}
              mute={dimmed}
            />
            <Label x={x} y={rowY + EXIT_DY} text={`exit ${VERDICT[kind].exit}`} color={C.dim} opacity={appear * rowO} />
          </React.Fragment>
        );
      })}

      <Chip x={SLOT_X[2]} top={rowY + CHIP_DY[0]} text="gap: named" color={ROLE.cannotVerify} at={gap} opacity={rowO} />
      <Chip x={SLOT_X[3]} top={rowY + CHIP_DY[0]} text="fresh identifier" color={ROLE.unstable} at={fresh} opacity={rowO} />
      <Chip x={SLOT_X[3]} top={rowY + CHIP_DY[1]} text="clock reading" color={ROLE.unstable} at={clock} opacity={rowO} />

      {/* The balance: a stand, a beam on its pivot, and two pans hung on strings. */}
      <Svg opacity={balO}>
        <DrawPath d={`M ${PIVOT.x - 55} ${FLOOR} L ${PIVOT.x} ${PIVOT.y + 8} L ${PIVOT.x + 55} ${FLOOR}`} at={worst} dur={0.6} color={C.dim} width={5} />
        <Line from={[PIVOT.x - 110, FLOOR]} to={[PIVOT.x + 110, FLOOR]} at={worst + s(0.2)} dur={0.5} color={C.dim} width={5} />
        <Line from={[PIVOT.x, PIVOT.y]} to={[left.x, left.y]} at={beamAt} dur={0.6} color={C.text} width={7} />
        <Line from={[PIVOT.x, PIVOT.y]} to={[right.x, right.y]} at={beamAt} dur={0.6} color={C.text} width={7} />
        {frame >= beamAt && <circle cx={PIVOT.x} cy={PIVOT.y} r={10 * prog(frame, beamAt, 0.3, fps)} fill={C.text} />}
        <Line from={[left.x, left.y]} to={[left.x - PAN, rimL]} at={stringAt} dur={0.35} color={C.dim} width={2.5} />
        <Line from={[left.x, left.y]} to={[left.x + PAN, rimL]} at={stringAt} dur={0.35} color={C.dim} width={2.5} />
        <Line from={[right.x, right.y]} to={[right.x - PAN, rimR]} at={stringAt} dur={0.35} color={C.dim} width={2.5} />
        <Line from={[right.x, right.y]} to={[right.x + PAN, rimR]} at={stringAt} dur={0.35} color={C.dim} width={2.5} />
        <DrawPath d={bowl(left.x, rimL)} at={panAt} dur={0.5} color={ROLE.cannotVerify} width={4} fill={`${ROLE.cannotVerify}1E`} />
        <DrawPath d={bowl(right.x, rimR)} at={panAt} dur={0.5} color={ROLE.diverged} width={4} fill={`${ROLE.diverged}1E`} />
      </Svg>

      <div style={{ position: "absolute", inset: 0, opacity: balO }}>
        <Text x={left.x} y={rimL + 64} size={34} color={ROLE.cannotVerify} at={alarm} dur={0.5}>
          false alarm
        </Text>
        <Text x={left.x} y={rimL + 104} size={28} italic color={C.dim} at={hour} reveal="fade">
          an hour lost
        </Text>
        <Text x={right.x} y={rimR + 64} size={34} color={ROLE.diverged} at={green} dur={0.5}>
          false green
        </Text>
        <Text x={right.x} y={rimR + 104} size={28} italic color={ROLE.diverged} at={ships} reveal="fade">
          a bug shipped
        </Text>
      </div>

      {frame >= why && (
        <VerdictSlot
          x={mix(SLOT_X[2], HERO.x, lift)}
          y={mix(rowY, HERO.y, lift)}
          kind="cannotVerify"
          appear={1}
          fill={1}
          opacity={mix(0.25, 1, lift)}
          glow={lift * breathe(why, 1)}
          scale={mix(1, 1.12, lift)}
          mute={1 - lift}
        />
      )}
      <Text x={HERO.x} y={HERO.y + 88} size={30} italic color={ROLE.cannotVerify} at={rather} dur={0.7}>
        not enough seen → no green
      </Text>
    </>
  );
};
