import React from "react";
import { useScene, Arrow, Fade, Line, Node, Svg, Text, C, FONT, mix, prog, track, visibility } from "#kit";
import { CodeCard, ROLE, Verdict, useAppear } from "./shared";

// Sources. The card is the README's stamp example (real). The timeline of refreshes and the stuck port
// are illustrative, after SettlePointTests.swift's StuckSettleFeed. The divergence line is reconstructed
// from SchedulingStampTests.swift:231-235 and DiffProjection.swift:294.

const README = [
  "@Haruspec(schedules: .serial)",
  "protocol StateQueue: SerialQueueing {",
  "    func async(_ work: @escaping () -> Void)   // held, run in order",
  "    func sync(_ work: () -> Void)              // the queue's held work, then inline",
  "}",
];

const REPORT_LINE = "≠ ParcelDidPost: ran on a different domain (main → queue(serial):DepotQueue)";

// The card, full size in the first phase; it then shrinks into the top-left corner.
const CODE_SIZE = 26;
const LH = CODE_SIZE * 1.55;
const CARD = { x: 960, y: 645, w: 1380 };
const CARD_H = 52 + README.length * LH + 36;
const CARD_TOP = CARD.y - CARD_H / 2;
const CARD_LEFT = CARD.x - CARD.w / 2;
const SHRUNK = { left: 80, top: 130, scale: 0.7 };
const col = (c: number) => CARD_LEFT + 3 + 24 + c * CODE_SIZE * 0.6;
const LINE0_Y = CARD_TOP + 3 + 54 + 18 + LH / 2;

// The timeline: three operations, two gaps, then the trace the held work drains into.
const ROW = 500;
const PORT_ROW = 820;
const OP_SIZE = 30;
const opWidth = (text: string) => text.length * OP_SIZE * 0.6 + 46;
const OPS = [
  { text: "refresh", x: 240 + opWidth("refresh") / 2 },
  { text: "refresh", x: 611 + opWidth("refresh") / 2 },
  { text: "checkout", x: 982 + opWidth("checkout") / 2 },
];
const GAPS = [511, 882];
const TRAY = { x: 700, y: 720, w: 420, slots: [580, 700, 820] };
const STRIP = { left: 1240, w: 360, slots: [1310, 1420, 1530] };
const RUNS = [612, 712];

// The main-thread phase.
const BASE_X = 560;
const PORT_X = 1400;
const CHIP_Y = 480;

type P = [number, number];
type Leg = { at: number; dur: number; from: P; ctrl: P; to: P };

const quad = (a: P, c: P, b: P, t: number): P => {
  const u = 1 - t;
  return [u * u * a[0] + 2 * u * t * c[0] + t * t * b[0], u * u * a[1] + 2 * u * t * c[1] + t * t * b[1]];
};

/** Where something travelling along `legs` (sorted by start) is now; null before the first leg. */
function follow(frame: number, fps: number, legs: Leg[]): P | null {
  let pos: P | null = null;
  for (const leg of legs) {
    if (frame < leg.at) break;
    pos = quad(leg.from, leg.ctrl, leg.to, prog(frame, leg.at, leg.dur, fps));
  }
  return pos;
}

/** A unit of held work: a numbered teal square. `x`/`y` are its centre. */
const Block: React.FC<{ x: number; y: number; n: number; opacity: number; glow?: number; size?: number }> = ({ x, y, n, opacity, glow = 0, size = 60 }) => {
  if (opacity <= 0) return null;
  const color = ROLE.seam;
  return (
    <div
      style={{
        position: "absolute",
        left: x - size / 2,
        top: y - size / 2,
        width: size,
        height: size,
        boxSizing: "border-box",
        border: `3px solid ${color}`,
        borderRadius: 10,
        background: `linear-gradient(${color}30, ${color}30), ${C.bg}`,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: FONT.mono,
        fontWeight: 600,
        fontSize: size * 0.47,
        color: C.text,
        opacity,
        boxShadow: glow > 0 ? `0 0 ${30 * glow}px ${color}` : "none",
      }}
    >
      {n}
    </div>
  );
};

/** An operation pill on a timeline. `broken` (0…1) turns it into a dashed, faded no-op. */
const Op: React.FC<{ x: number; y: number; text: string; color: string; at: number; out?: number; broken?: number }> = ({ x, y, text, color, at, out, broken = 0 }) => {
  const { frame, fps } = useScene();
  const p = frame < at ? 0 : prog(frame, at, 0.4, fps) * visibility(frame, fps, undefined, out);
  if (p <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x - opWidth(text) / 2,
        top: y - 28,
        width: opWidth(text),
        height: 56,
        boxSizing: "border-box",
        border: `2.5px ${broken > 0.5 ? "dashed" : "solid"} ${color}`,
        borderRadius: 999,
        background: C.bg,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: FONT.mono,
        fontSize: OP_SIZE,
        color,
        opacity: p,
        transform: `translateY(${(1 - p) * 10}px)`,
      }}
    >
      <span style={{ opacity: mix(1, 0.35, broken) }}>{text}</span>
    </div>
  );
};

/** A strip of slots the held work drains into. `y` is its centre. */
const Strip: React.FC<{ y: number; h: number; color: string; opacity: number }> = ({ y, h, color, opacity }) =>
  opacity <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: STRIP.left,
        top: y - h / 2,
        width: STRIP.w,
        height: h,
        boxSizing: "border-box",
        border: `2.5px solid ${color}`,
        borderLeft: `6px solid ${color}`,
        borderRadius: 12,
        background: `${color}14`,
        opacity,
      }}
    />
  );

const DIAL_LABELS: [string, number][] = [
  ["held", 150],
  ["ready", 90],
  ["elapsed", 30],
];

/** A three-way settle-point dial; `angle` (degrees, 150 held … 30 elapsed) places the needle. */
const Dial: React.FC<{ x: number; y: number; at: number; out: number; angle: number }> = ({ x, y, at, out, angle }) => {
  const { frame, fps } = useScene();
  const o = frame < at ? 0 : prog(frame, at, 0.5, fps) * visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  const r = 46;
  const pt = (deg: number, k: number): P => [x + k * r * Math.cos((deg * Math.PI) / 180), y - k * r * Math.sin((deg * Math.PI) / 180)];
  const tip = pt(angle, 0.86);
  const near = (deg: number) => Math.abs(angle - deg) < 12;
  return (
    <>
      <Svg opacity={o}>
        <path d={`M ${x - r} ${y} A ${r} ${r} 0 0 1 ${x + r} ${y}`} fill="none" stroke={C.faint} strokeWidth={4} />
        {DIAL_LABELS.map(([, deg]) => {
          const [dx, dy] = pt(deg, 1);
          return <circle key={deg} cx={dx} cy={dy} r={5} fill={near(deg) ? ROLE.seam : C.dim} />;
        })}
        <line x1={x} y1={y} x2={tip[0]} y2={tip[1]} stroke={ROLE.seam} strokeWidth={4} strokeLinecap="round" />
        <circle cx={x} cy={y} r={7} fill={ROLE.seam} />
      </Svg>
      {DIAL_LABELS.map(([label, deg]) => {
        const color = near(deg) ? ROLE.seam : C.dim;
        const props =
          deg === 150
            ? { x: x - r - 12, y: y - 24, anchor: "right" as const }
            : deg === 90
              ? { x, y: y - r - 26 }
              : { x: x + r + 12, y: y - 24, anchor: "left" as const };
        return (
          <Text key={label} {...props} size={26} font="mono" color={color} at={at} out={out} reveal="fade">
            {label}
          </Text>
        );
      })}
    </>
  );
};

/** An event chip: `name · domain`, in a role colour; the domain may take its own colour. */
const Chip: React.FC<{ x: number; y: number; name: string; domain: string; color: string; domainColor?: string; at: number; glow?: number }> = ({
  x,
  y,
  name,
  domain,
  color,
  domainColor,
  at,
  glow = 0,
}) => {
  const o = useAppear(at, undefined, 0.5);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) translateY(${(1 - o) * 12}px)`,
        fontFamily: FONT.mono,
        fontSize: 28,
        color,
        border: `2.5px solid ${color}`,
        borderRadius: 999,
        background: `${color}1E`,
        padding: "6px 24px",
        whiteSpace: "nowrap",
        opacity: o,
        boxShadow: glow > 0 ? `0 0 ${30 * glow}px ${color}` : "none",
      }}
    >
      {name} <span style={{ color: C.dim }}>·</span> <span style={{ color: domainColor ?? color }}>{domain}</span>
    </div>
  );
};

export const Threads: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);
  const pulse = (t: number, len = 0.7) => (frame >= t && frame < t + s(len) ? Math.sin(((frame - t) / s(len)) * Math.PI) : 0);
  const breathe = (t: number) => (frame >= t ? 0.5 + 0.5 * Math.sin(((frame - t) / fps) * Math.PI * 2 * 0.8) : 0);

  // Phase 1: the stamp.
  const open = cue("Threads are collaborators");
  const subject = cue("A subject");
  const takes = cue("takes that queue");
  const initializer = cue("initializer");
  const production = cue("a real dispatch queue");
  const testTarget = cue("The test target");
  const stamps = cue("stamps the protocol");
  const serial = cue("serial");
  const concurrent = cue("concurrent");
  const orMain = cue("or main");
  // Phase 2: held work.
  const underTest = cue("Under test");
  const holds = cue("holds every piece");
  const peels = [cue("every piece"), cue("piece of work"), cue("work it's handed")];
  const capture = cue("The capture runs it");
  const drains = [cue("after the operations"), cue("one item"), cue("at a time")];
  const enqueue = cue("in enqueue order");
  const sameWay = cue("the same way every run");
  // Phase 3: settle points.
  const between = cue("Between operations");
  const settle = cue("settle points");
  const lands = cue("where held work lands");
  const paused = cue("as if the user paused");
  const landAt = cue("paused");
  const soPort = cue("So a port");
  const landed = cue("refresh has landed");
  const nothing = cue("landed");
  const caught = cue("still gets caught");
  // Phase 4: main-actor work.
  const toMain = cue("Work handed to the main queue");
  const mainQueue = cue("main queue");
  const mainThread = cue("main thread");
  const mainActor = cue("main actor");
  const records = cue("records as main");
  const aPort = cue("A port that quietly");
  const drops = cue("drops its hop");
  const toMainHop = cue("to main", { after: drops });
  const diverges = cue("diverges");
  const report = cue("the report names");

  // The card shrinks into the top-left corner under test, and leaves for the settle points.
  const k = prog(frame, underTest, 0.9, fps);
  const scale = mix(1, SHRUNK.scale, k);
  const tx = mix(0, SHRUNK.left - CARD_LEFT, k);
  const ty = mix(0, SHRUNK.top - CARD_TOP, k);
  const ghost = (at: number) => {
    if (frame < at) return 0;
    const t = (frame - at) / fps;
    const flick = t < 0.45 ? (Math.floor((frame - at) / 3) % 2 === 0 ? 1 : 0.2) : 1;
    return flick * 0.75 * visibility(frame, fps, undefined, underTest);
  };

  // Held work: each block peels off its operation into the tray, drains into the trace in order, and
  // block 1 later lands in the first gap instead.
  const peelDur = 0.8;
  const drainDur = 0.9;
  const blockLegs: Leg[][] = OPS.map((op, i) => {
    const legs: Leg[] = [
      { at: peels[i], dur: peelDur, from: [op.x, ROW + 30], ctrl: [op.x, TRAY.y], to: [TRAY.slots[i], TRAY.y] },
      { at: drains[i], dur: drainDur, from: [TRAY.slots[i], TRAY.y], ctrl: [STRIP.slots[i], TRAY.y], to: [STRIP.slots[i], ROW] },
    ];
    if (i === 0) legs.push({ at: landAt, dur: 1.0, from: [STRIP.slots[0], ROW], ctrl: [910, 700], to: [GAPS[0], ROW] });
    return legs;
  });
  const phase3Out = toMain;
  const blockOpacity = (i: number) => (frame < peels[i] ? 0 : prog(frame, peels[i], 0.3, fps) * visibility(frame, fps, undefined, phase3Out));

  // The settle-point dials explore, then the first settles on `elapsed`.
  const dial1 = track(frame, fps, [[0, 150], [lands, 90], [paused, 30]], 0.6);
  const dial2 = track(frame, fps, [[0, 150], [lands, 90], [paused, 150]], 0.6);

  const stripO = (frame < capture ? 0 : prog(frame, capture, 0.5, fps)) * visibility(frame, fps, undefined, phase3Out);
  const runsO = (frame < sameWay ? 0 : prog(frame, sameWay, 0.5, fps)) * visibility(frame, fps, undefined, between);
  const portBroken = prog(frame, nothing, 0.5, fps);
  const port1 = follow(frame, fps, [{ at: landed, dur: 0.6, from: [GAPS[0], PORT_ROW - 70], ctrl: [GAPS[0], PORT_ROW - 40], to: [GAPS[0], PORT_ROW] }]);
  const port1O = frame < landed ? 0 : prog(frame, landed, 0.3, fps) * visibility(frame, fps, undefined, phase3Out);

  // Main thread: the stamp slams down; the report line types in.
  const stampP = frame < mainQueue ? 0 : prog(frame, mainQueue, 0.35, fps);
  const strike = prog(frame, drops, 0.4, fps);
  const typed = frame < report ? 0 : Math.min(REPORT_LINE.length, Math.floor(((frame - report) / fps) * 60));
  const reportO = useAppear(report, undefined, 0.45);

  return (
    <>
      {/* ── Phase 1: the queue comes in through the initializer, and the test target stamps it. ── */}
      <Node x={1330} y={300} w={300} h={110} label="subject" color={C.text} size={34} at={subject} out={underTest} />
      <Svg>
        <Arrow from={[1330, 490]} to={[1330, 362]} at={takes} out={underTest} dur={0.5} color={ROLE.seam} />
        <Arrow from={[878, 300]} to={[1172, 300]} at={production + s(0.3)} out={underTest} dur={0.5} color={C.dim} />
      </Svg>
      <Text x={1352} y={426} size={28} italic color={ROLE.seam} anchor="left" at={initializer} out={underTest} reveal="fade">
        initializer
      </Text>
      <Fade x={640} y={300} anchor="center" at={production} out={underTest} rise={10}>
        <div
          style={{
            border: `2.5px solid ${C.dim}`,
            borderRadius: 14,
            background: C.surface,
            padding: "14px 28px",
            whiteSpace: "nowrap",
            display: "flex",
            alignItems: "baseline",
            gap: 14,
          }}
        >
          <span style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 30, color: C.dim }}>production:</span>
          <span style={{ fontFamily: FONT.mono, fontSize: 30, color: C.text }}>DispatchQueue</span>
        </div>
      </Fade>
      <Text x={CARD_LEFT + 27} y={466} size={28} italic color={ROLE.seam} anchor="left" at={testTarget} out={underTest} reveal="fade">
        test target
      </Text>

      <div
        style={{
          position: "absolute",
          left: 0,
          top: 0,
          width: 1920,
          height: 1080,
          transformOrigin: `${CARD_LEFT}px ${CARD_TOP}px`,
          transform: `translate(${tx}px, ${ty}px) scale(${scale})`,
        }}
      >
        <CodeCard
          x={CARD.x}
          y={CARD.y}
          w={CARD.w}
          file="README.md"
          lines={README}
          color={C.text}
          size={CODE_SIZE}
          at={open}
          out={between}
          marks={[
            { line: 0, at: stamps, color: ROLE.seam },
            { line: 2, at: holds, color: ROLE.seam },
          ]}
        />
        {/* `.serial` glows; its two alternatives flick in beside it. */}
        <Fade x={(col(21) + col(28)) / 2} y={LINE0_Y} anchor="center" at={serial} out={underTest} rise={0}>
          <div style={{ width: col(28) - col(21) + 12, height: 40, borderRadius: 8, border: `2.5px solid ${ROLE.seam}`, boxShadow: `0 0 ${24 * breathe(serial)}px ${ROLE.seam}` }} />
        </Fade>
        {[
          { text: ".concurrent", x: col(31), at: concurrent },
          { text: ".main", x: col(46), at: orMain },
        ].map((g) => (
          <div
            key={g.text}
            style={{
              position: "absolute",
              left: g.x,
              top: LINE0_Y - 20,
              height: 40,
              boxSizing: "border-box",
              border: `2px dashed ${ROLE.seam}`,
              borderRadius: 8,
              padding: "0 10px",
              display: "flex",
              alignItems: "center",
              fontFamily: FONT.mono,
              fontSize: CODE_SIZE,
              color: ROLE.seam,
              opacity: ghost(g.at),
            }}
          >
            {g.text}
          </div>
        ))}
      </div>

      {/* ── Phase 2: the double holds the work; the capture runs it after the operations, in order. ── */}
      <Svg>
        <Line from={[190, ROW]} to={[STRIP.left - 6, ROW]} at={underTest + s(0.3)} out={phase3Out} dur={0.8} color={C.faint} width={3} />
        {GAPS.map((gx) => (
          <Line key={gx} from={[gx, 438]} to={[gx, 562]} at={between + s(0.2)} out={phase3Out} dur={0.4} color={ROLE.seam} width={3} dashed />
        ))}
      </Svg>
      {OPS.map((op, i) => (
        <Op key={i} x={op.x} y={ROW} text={op.text} color={C.text} at={underTest + s(0.5 + 0.2 * i)} out={phase3Out} />
      ))}

      <Fade x={TRAY.x} y={TRAY.y} anchor="center" at={holds} out={sameWay} rise={0}>
        <div style={{ width: TRAY.w, height: 96, boxSizing: "border-box", border: `2.5px dashed ${ROLE.seam}`, borderRadius: 14, background: `${ROLE.seam}0C` }} />
      </Fade>
      <Text x={TRAY.x - TRAY.w / 2 - 22} y={TRAY.y} size={30} italic color={ROLE.seam} anchor="right" at={holds} out={sameWay} reveal="fade">
        held
      </Text>

      <Strip y={ROW} h={96} color={ROLE.baseline} opacity={stripO} />
      <Text x={STRIP.left} y={428} size={28} italic color={ROLE.baseline} anchor="left" at={capture} out={phase3Out} reveal="fade">
        trace
      </Text>

      {/* Every run drains the same way. */}
      {RUNS.map((y, r) => (
        <React.Fragment key={y}>
          <Strip y={y} h={76} color={ROLE.baseline} opacity={runsO * 0.6} />
          {STRIP.slots.map((x, i) => (
            <Block key={i} x={x} y={y} n={i + 1} size={46} opacity={runsO * 0.6} />
          ))}
          <Text x={STRIP.left + STRIP.w + 26} y={y} size={26} italic color={C.dim} anchor="left" at={sameWay + s(0.2 * (r + 1))} out={between} reveal="fade">
            {`run ${r + 2}`}
          </Text>
        </React.Fragment>
      ))}
      <Text x={STRIP.left + STRIP.w + 26} y={ROW} size={26} italic color={C.dim} anchor="left" at={sameWay} out={between} reveal="fade">
        run 1
      </Text>

      {OPS.map((_, i) => {
        const p = follow(frame, fps, blockLegs[i]);
        if (!p) return null;
        const glow = Math.max(pulse(enqueue + s(0.3 * i)), i === 0 ? pulse(landAt + s(1.0), 0.9) : 0);
        return <Block key={i} x={p[0]} y={p[1]} n={i + 1} opacity={blockOpacity(i)} glow={glow} />;
      })}

      {/* ── Phase 3: settle points between operations. ── */}
      <Dial x={GAPS[0]} y={410} at={settle} out={phase3Out} angle={dial1} />
      <Dial x={GAPS[1]} y={410} at={settle + s(0.25)} out={phase3Out} angle={dial2} />
      <Fade x={GAPS[0]} y={600} anchor="center" at={landAt + s(1.0)} out={phase3Out} rise={8}>
        <div style={{ fontFamily: FONT.mono, fontSize: 28, color: C.text, whiteSpace: "nowrap" }}>
          refresh <span style={{ color: C.dim }}>→</span> <span style={{ color: ROLE.seam }}>settle:elapsed</span> <span style={{ color: C.dim }}>→</span> refresh
        </div>
      </Fade>

      {/* The port's strip (illustrative): its second refresh does nothing once the first has landed. */}
      <Text x={220} y={ROW} size={28} italic color={ROLE.baseline} anchor="right" at={soPort} out={phase3Out} reveal="fade">
        baseline
      </Text>
      <Text x={220} y={PORT_ROW - 16} size={28} italic color={ROLE.candidate} anchor="right" at={soPort} out={phase3Out} reveal="fade">
        port
      </Text>
      <Text x={220} y={PORT_ROW + 22} size={26} italic color={C.dim} anchor="right" at={soPort + s(0.3)} out={phase3Out} reveal="fade">
        illustrative
      </Text>
      <Svg>
        <Line from={[190, PORT_ROW]} to={[1200, PORT_ROW]} at={soPort} out={phase3Out} dur={0.8} color={`${ROLE.candidate}66`} width={3} />
      </Svg>
      {OPS.map((op, i) => (
        <Op key={i} x={op.x} y={PORT_ROW} text={op.text} color={ROLE.candidate} at={soPort + s(0.2 * i)} out={phase3Out} broken={i === 1 ? portBroken : 0} />
      ))}
      {port1 && <Block x={port1[0]} y={port1[1]} n={1} opacity={port1O} />}
      <Text x={OPS[1].x} y={PORT_ROW + 58} size={26} italic color={ROLE.candidate} at={nothing + s(0.2)} out={phase3Out} reveal="fade">
        does nothing
      </Text>
      <Verdict x={1440} y={PORT_ROW} kind="diverged" size={32} at={caught} out={phase3Out} />

      {/* ── Phase 4: main-queue work runs on, and records as, main. ── */}
      {stampP > 0 && (
        <div
          style={{
            position: "absolute",
            left: 420,
            top: 280,
            transform: `translate(-50%, -50%) rotate(-6deg) scale(${mix(1.5, 1, stampP)})`,
            opacity: stampP,
            fontFamily: FONT.mono,
            fontWeight: 600,
            fontSize: 40,
            color: ROLE.seam,
            border: `5px double ${ROLE.seam}`,
            borderRadius: 12,
            padding: "4px 26px",
            background: `${ROLE.seam}14`,
            whiteSpace: "nowrap",
          }}
        >
          .main
        </div>
      )}
      <Text x={730} y={280} size={32} font="mono" color={C.text} at={mainActor} reveal="fade">
        @MainActor
      </Text>
      <Svg>
        <Arrow from={[445, 330]} to={[530, 448]} at={mainThread} dur={0.4} color={ROLE.seam} />
        <Arrow from={[715, 312]} to={[598, 448]} at={records} dur={0.4} color={C.dim} />
      </Svg>
      <Chip x={BASE_X} y={CHIP_Y} name="ParcelDidPost" domain="main" color={ROLE.baseline} at={mainThread} glow={Math.max(pulse(records + s(0.4), 0.8), 0)} />
      <Text x={BASE_X} y={CHIP_Y + 66} size={28} italic color={ROLE.baseline} at={mainThread + s(0.3)} reveal="fade">
        baseline
      </Text>

      {/* The port drops its hop to main. */}
      <Fade x={PORT_X} y={280} anchor="center" at={aPort} rise={8}>
        <div style={{ position: "relative", border: `2.5px dashed ${C.dim}`, borderRadius: 12, padding: "8px 26px", fontFamily: FONT.serif, fontStyle: "italic", fontSize: 30, color: C.dim, whiteSpace: "nowrap" }}>
          hop to main
          <div style={{ position: "absolute", left: 12, top: "50%", height: 4, width: `calc(${strike * 100}% - 24px)`, background: ROLE.diverged, borderRadius: 2 }} />
        </div>
      </Fade>
      <Chip
        x={PORT_X}
        y={CHIP_Y}
        name="ParcelDidPost"
        domain="queue(serial):DepotQueue"
        color={ROLE.candidate}
        domainColor={frame >= diverges ? ROLE.diverged : ROLE.candidate}
        at={toMainHop}
      />
      <Text x={PORT_X} y={CHIP_Y + 66} size={28} italic color={ROLE.candidate} at={aPort} reveal="fade">
        port
      </Text>
      <Text x={896} y={CHIP_Y} size={56} font="mono" color={ROLE.diverged} at={diverges}>
        ≠
      </Text>

      {/* The report names where the work went. */}
      {reportO > 0 && (
        <div
          style={{
            position: "absolute",
            left: 960 - 730,
            top: 700 - 42,
            width: 1460,
            height: 84,
            boxSizing: "border-box",
            borderRadius: 16,
            border: `3px solid ${ROLE.diverged}`,
            background: C.surface,
            padding: "0 32px",
            display: "flex",
            alignItems: "center",
            fontFamily: FONT.mono,
            fontSize: 28,
            color: ROLE.diverged,
            whiteSpace: "pre",
            opacity: reportO,
            transform: `translateY(${(1 - reportO) * 24}px)`,
          }}
        >
          {REPORT_LINE.slice(0, typed)}
        </div>
      )}
      <Text x={960} y={790} size={26} italic color={C.dim} at={report + s(0.6)} reveal="fade">
        reconstructed from SchedulingStampTests.swift:231-235 and DiffProjection.swift:294
      </Text>
    </>
  );
};
