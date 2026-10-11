import React from "react";
import { useScene, Arrow, Box, Fade, Line, Pill, Svg, Text, C, FONT, MONO_ADVANCE, mix, prog, track, visibility } from "#kit";
import { CodeCard, ROLE, TraceStrip, useAppear } from "./shared";

// The card is the Cart protocol in example-xcode-migration's SubjectBoundaries.swift (lines 32–51),
// abridged: its method and property requirements are elided. The failure message is
// SystemResolution.swift:222–226, abridged, naming the card's OrderArchiving. The trace row and the
// generated value are illustrative.

const CODE = [
  "@Haruspec protocol Cart: AnyObject {",
  "    init(",
  "        inventory: InventoryReserving,",
  "        analytics: AnalyticsTracking,",
  "        notificationCenter: NotificationCenter,",
  "        orderArchive: OrderArchiving,",
  "        stateQueue: SerialQueueing,",
  "        newOrderID: @escaping () -> UUID,",
  "        clock: @escaping () -> Date",
  "    )",
  "    …",
  "}",
];

const MESSAGE = [
  "nothing serves OrderArchiving — declare it:",
  '  paste its protocol under @Haruspec("<label>") refining OrderArchiving,',
  "  provide it as a capture resource: .provides(OrderArchiving.self) { context in … },",
  "  or author the wiring: .baselined { context in … }",
];

const RUNGS = ["1 · what the spec provides", "2 · the capture's notification center", "3 · the one stamped double serving that type"];

// Card layout (CodeCard: 3 px border, 52 px header, 18 px body padding, text 27 px in from the left).
const CARD = { left: 80, w: 820, size: 26 } as const;
const LH = CARD.size * 1.55;
const CARD_H = 52 + CODE.length * LH + 36;
const ADV = CARD.size * MONO_ADVANCE;
/** The card's top edge before and after it rises to make room for the message. */
const TOP = { start: 240, end: 130 } as const;

/** Vertical centre of card line `i` when the card's top edge is at `top`. */
const lineY = (top: number, i: number) => top + 3 + 52 + 18 + i * LH + LH / 2;
/** Left edge of card column `c`. */
const colX = (c: number) => CARD.left + 27 + c * ADV;

/** The initializer's parameters: the card line each sits on (all indented 8 columns). */
const PARAM = { inventory: 2, analytics: 3, notificationCenter: 4, orderArchive: 5, stateQueue: 6, newOrderID: 7, clock: 8 } as const;
type Param = keyof typeof PARAM;
const nameSpan = (p: Param) => ({ x0: colX(8), x1: colX(8 + p.length), line: PARAM[p] });

// The ladder, on the right.
const LADDER = { left: 980, w: 860, rungH: 68, ys: [320, 408, 496] } as const;
// The stamped double and what it produces.
const DOUBLE = { x: 1140, y: 655, w: 320, h: 80 } as const;
const CHIP_X = 1509;
const STRIP = { x: 980, y: 740 } as const;
// The failure message, right-aligned beneath the risen card.
const MSG = { w: 1380, top: 740, lh: 42, cps: 90 } as const;

/** An underline under one parameter name, teal unless `color` says otherwise. Inside `<Svg>`. */
const Underline: React.FC<{ top: number; p: Param; at: number; color?: string; dur?: number }> = ({ top, p, at, color = ROLE.seam, dur = 0.4 }) => {
  const { x0, x1, line } = nameSpan(p);
  const y = lineY(top, line) + 15;
  return <Line from={[x0, y]} to={[x1, y]} at={at} dur={dur} color={color} width={3} />;
};

/** A tint over one parameter name while a rung (or the failure) is about it. */
const Tint: React.FC<{ top: number; p: Param; at: number; out?: number; color?: string }> = ({ top, p, at, out, color = ROLE.seam }) => {
  const o = useAppear(at, out, 0.35);
  if (o <= 0) return null;
  const { x0, x1, line } = nameSpan(p);
  const y = lineY(top, line);
  return (
    <div
      style={{
        position: "absolute",
        left: x0 - 6,
        top: y - LH / 2 + 3,
        width: x1 - x0 + 12,
        height: LH - 6,
        borderRadius: 6,
        background: `${color}3A`,
        opacity: o,
      }}
    />
  );
};

/** A polyline that draws on from its first point, with a dot where it starts. Inside `<Svg>`. */
const Elbow: React.FC<{ pts: [number, number][]; at: number; out?: number; dur?: number; color: string }> = ({ pts, at, out, dur = 0.7, color }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const o = visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  const p = prog(frame, at, dur, fps);
  const len = pts.slice(1).reduce((sum, [x, y], i) => sum + Math.hypot(x - pts[i][0], y - pts[i][1]), 0);
  const d = pts.map(([x, y], i) => `${i === 0 ? "M" : "L"} ${x} ${y}`).join(" ");
  return (
    <g opacity={o}>
      <circle cx={pts[0][0]} cy={pts[0][1]} r={6} fill={color} opacity={Math.min(1, p * 3)} />
      <path d={d} fill="none" stroke={color} strokeWidth={3} strokeLinejoin="round" strokeDasharray={len} strokeDashoffset={len * (1 - p)} />
    </g>
  );
};

/** One rung of the ladder: a row that writes on, ringed teal while it's the one being spoken. */
const Rung: React.FC<{ i: number; at: number; until: number }> = ({ i, at, until }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.4);
  if (o <= 0) return null;
  const active = prog(frame, at, 0.4, fps) * visibility(frame, fps, undefined, until);
  const y = LADDER.ys[i];
  const box = (border: string, opacity: number) => (
    <div
      style={{
        position: "absolute",
        left: LADDER.left,
        top: y - LADDER.rungH / 2,
        width: LADDER.w,
        height: LADDER.rungH,
        boxSizing: "border-box",
        borderRadius: 12,
        border: `2.5px solid ${border}`,
        background: opacity === 1 ? C.surface : "transparent",
        opacity,
      }}
    />
  );
  return (
    <>
      {box(C.faint, o)}
      {active > 0 && box(ROLE.seam, active)}
      <Text x={LADDER.left + 26} y={y} size={32} anchor="left" at={at} dur={0.4 + RUNGS[i].length * 0.022}>
        {RUNGS[i]}
      </Text>
    </>
  );
};

/** The generated value the double answers with: pops out of the double's right edge. */
const Chip: React.FC<{ at: number; out: number }> = ({ at, out }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, 0.5, fps);
  const o = p * visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: mix(DOUBLE.x + DOUBLE.w / 2, CHIP_X, p),
        top: DOUBLE.y,
        transform: `translate(-50%, -50%) scale(${mix(0.4, 1, p)})`,
        fontFamily: FONT.mono,
        fontSize: 26,
        color: C.text,
        border: `2.5px solid ${ROLE.seam}`,
        background: `${ROLE.seam}1E`,
        borderRadius: 999,
        padding: "4px 18px",
        whiteSpace: "nowrap",
        opacity: o,
      }}
    >
      Inventory.stock → 0
    </div>
  );
};

/** The call the double records: drops out of the double into the trace strip's row. */
const DroppedRow: React.FC<{ at: number; out: number }> = ({ at, out }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, 0.6, fps);
  const o = Math.min(1, p * 1.6) * visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: STRIP.x + 20,
        top: mix(DOUBLE.y + DOUBLE.h / 2 - 20, STRIP.y + 39, p),
        fontFamily: FONT.mono,
        fontSize: 26,
        lineHeight: "39px",
        color: C.text,
        whiteSpace: "pre",
        opacity: o,
      }}
    >
      call Inventory.reserve
    </div>
  );
};

/** The failure: a red-bordered message that types in, its first line underlined from `underlineAt`. */
const Message: React.FC<{ at: number; underlineAt: number }> = ({ at, underlineAt }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.4);
  if (o <= 0) return null;
  const typeAt = at + Math.round(0.3 * fps);
  let left = Math.max(0, ((frame - typeAt) / fps) * MSG.cps);
  const shown = MESSAGE.map((ln) => {
    const n = Math.floor(Math.min(ln.length, left));
    left -= ln.length;
    return ln.slice(0, Math.max(0, n));
  });
  const ul = frame >= underlineAt ? prog(frame, underlineAt, 0.5, fps) : 0;
  return (
    <div
      style={{
        position: "absolute",
        left: 1840 - MSG.w,
        top: MSG.top,
        width: MSG.w,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${ROLE.diverged}`,
        background: C.surface,
        padding: "18px 30px 22px",
        opacity: o,
        transform: `translateY(${(1 - o) * 24}px)`,
      }}
    >
      <div style={{ position: "absolute", right: 24, top: 14, fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, color: C.dim }}>abridged</div>
      {shown.map((text, i) => (
        <div key={i} style={{ fontFamily: FONT.mono, fontSize: 26, height: MSG.lh, lineHeight: `${MSG.lh}px`, whiteSpace: "pre", color: C.text, fontWeight: i === 0 ? 600 : 400 }}>
          {text}
        </div>
      ))}
      {ul > 0 && (
        <div
          style={{
            position: "absolute",
            left: 30,
            top: 18 + MSG.lh - 5,
            width: ul * MESSAGE[0].length * ADV,
            height: 3,
            borderRadius: 2,
            background: ROLE.diverged,
          }}
        />
      )}
    </div>
  );
};

export const Initializer: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  // The rule.
  const rule = cue("The rule");
  const subject = cue("A subject");
  const depends = cue("depends on");
  const through = cue("through its initializer");
  const init = cue("initializer");
  const here = cue("Here's a real");
  const cart = cue("real cart's");
  // The real initializer's parameters.
  const collaborators = cue("collaborators");
  const notif = cue("notification center");
  const queue = cue("queue");
  const orderIds = cue("order identifiers");
  const clock = cue("clock");
  // The ladder.
  const builds = cue("builds the cart");
  const port = cue("your port");
  const fills = cue("fills every parameter");
  const same = cue("the same way");
  const first = cue("First");
  const second = cue("Then the notification center");
  const third = cue("Then the one stamped");
  const dbl = cue("the one stamped double");
  const records = cue("records each call");
  const generated = cue("generated input");
  // Nothing serves it.
  const nothing = cue("If nothing serves");
  const servesParam = cue("serves a parameter");
  const stops = cue("stops");
  const never = cue("never guesses");

  const top = track(frame, fps, [[0, TOP.start], [nothing, TOP.end]], 0.8);
  const grey = frame >= stops ? prog(frame, stops, 0.5, fps) : 0;
  const ladderFade = mix(1, 0.32, grey);
  const invY = lineY(top, PARAM.inventory);
  const invEnd = colX(CODE[PARAM.inventory].length) + 12;

  return (
    <>
      {/* The rule: everything the subject depends on comes in through one door. */}
      <Text x={960} y={330} size={44} at={rule} out={here}>
        the rule
      </Text>
      <Svg>
        <Box x={1180} y={600} w={440} h={260} at={subject} out={here} dur={0.6} color={C.dim} fill={C.surface} dashed />
        {[470, 600, 730].map((y, i) => (
          <Arrow key={i} from={[625, y]} to={[948, 600]} bend={(i - 1) * -18} at={through + s(i * 0.15)} out={here} dur={0.6} color={ROLE.seam} />
        ))}
        <Box x={960} y={600} w={12} h={120} r={4} at={init} out={here} dur={0.3} color={ROLE.seam} fill={ROLE.seam} />
      </Svg>
      <Text x={1270} y={600} size={40} at={subject + s(0.3)} out={here} reveal="fade">
        subject
      </Text>
      {["collaborators", "values", "threads"].map((label, i) => (
        <Text key={label} x={600} y={470 + i * 130} size={32} color={C.dim} anchor="right" at={depends + s(i * 0.2)} out={here} reveal="fade">
          {label}
        </Text>
      ))}
      <Text x={988} y={600} size={30} font="mono" color={ROLE.seam} anchor="left" at={init} out={here} dur={0.5}>
        init(…)
      </Text>

      {/* The real cart's initializer. */}
      <CodeCard x={CARD.left + CARD.w / 2} y={top + CARD_H / 2} w={CARD.w} file="SubjectBoundaries.swift" lines={CODE} color={C.text} at={cart} />
      <Text x={CARD.left + CARD.w - 24} y={top + 29} size={26} italic color={C.dim} anchor="right" at={cart + s(0.4)} reveal="fade">
        abridged
      </Text>

      {/* Which parameter each rung is filling. */}
      <Tint top={top} p="newOrderID" at={first} out={second} />
      <Tint top={top} p="clock" at={first} out={second} />
      <Tint top={top} p="notificationCenter" at={second} out={third} />
      <Tint top={top} p="inventory" at={dbl} out={nothing} />
      <Tint top={top} p="orderArchive" at={servesParam} color={ROLE.diverged} />

      <Svg>
        <Underline top={top} p="inventory" at={collaborators} />
        <Underline top={top} p="analytics" at={collaborators + s(0.15)} />
        <Underline top={top} p="orderArchive" at={collaborators + s(0.3)} />
        <Underline top={top} p="notificationCenter" at={notif} />
        <Underline top={top} p="stateQueue" at={queue} />
        <Underline top={top} p="newOrderID" at={orderIds} />
        <Underline top={top} p="clock" at={clock} />
        <Underline top={top} p="orderArchive" at={servesParam} color={ROLE.diverged} />
        <Elbow
          pts={[
            [invEnd, invY],
            [940, invY],
            [940, DOUBLE.y],
            [DOUBLE.x - DOUBLE.w / 2 - 2, DOUBLE.y],
          ]}
          at={dbl + s(0.25)}
          out={nothing}
          color={ROLE.seam}
        />
      </Svg>

      {/* Both sides, built the same way. */}
      <div style={{ opacity: ladderFade }}>
        <Pill x={1200} y={165} text="the cart" color={ROLE.baseline} at={builds} size={28} />
        <Pill x={1620} y={165} text="your port" color={ROLE.candidate} at={port} size={28} />
        <Svg>
          <Arrow from={[1240, 194]} to={[1350, 226]} at={same} dur={0.5} color={C.dim} />
          <Arrow from={[1580, 194]} to={[1470, 226]} at={same} dur={0.5} color={C.dim} />
        </Svg>
        <Text x={1410} y={250} size={32} italic color={C.dim} at={fills} reveal="fade">
          filling each parameter
        </Text>
        <Rung i={0} at={first} until={second} />
        <Rung i={1} at={second} until={third} />
        <Rung i={2} at={third} until={nothing} />
      </div>

      {/* The one stamped double: records calls, answers with generated input. */}
      <Text x={LADDER.left} y={DOUBLE.y - DOUBLE.h / 2 - 34} size={26} font="mono" color={C.dim} anchor="left" at={dbl + s(0.4)} out={nothing} dur={0.8}>
        @Haruspec protocol Inventory: InventoryReserving
      </Text>
      <Fade x={DOUBLE.x} y={DOUBLE.y} anchor="center" at={dbl} out={nothing} rise={0}>
        <div
          style={{
            width: DOUBLE.w,
            height: DOUBLE.h,
            boxSizing: "border-box",
            borderRadius: 14,
            border: `3px solid ${ROLE.seam}`,
            background: `linear-gradient(180deg, ${ROLE.seam}1C, ${ROLE.seam}08)`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontFamily: FONT.mono,
            fontSize: 28,
            color: C.text,
          }}
        >
          DoubleInventory
        </div>
      </Fade>
      <TraceStrip x={STRIP.x} y={STRIP.y} rows={[""]} color={ROLE.baseline} title="illustrative trace" at={records} out={nothing} />
      <DroppedRow at={records + s(0.15)} out={nothing} />
      <Chip at={generated} out={nothing} />
      <Text x={CHIP_X + 185} y={DOUBLE.y} size={26} italic color={C.dim} anchor="left" at={generated + s(0.4)} out={nothing} reveal="fade">
        illustrative
      </Text>

      {/* Nothing serves the parameter: the check stops and names what to write. */}
      <Message at={stops + s(0.2)} underlineAt={never} />
    </>
  );
};
