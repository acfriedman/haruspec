import React from "react";
import { useScene, Arrow, Fade, Line, Svg, Text, C, FONT, MONO_ADVANCE, mix, prog, track, visibility } from "#kit";
import { CodeCard, ROLE, STAGE, useAppear } from "./shared";

// Sources (dogfood app, example-xcode-migration): the Cart initializer, cut down to its two value
// parameters ("simplified"); CartMigrationSpec.swift lines 48–50 and FulfillmentMigrationSpec.swift
// lines 45 and 53, real. Two of StoreClock.instants are named (the Saturday, Christmas Eve); the other
// six date chips are unlabelled stand-ins, marked illustrative.

type Pt = [number, number];

const VALUES = ["clock", "fresh identifier", "random numbers", "user defaults", "keychain", "file", "locale", "network response"];
const VALUE_CUES = ["clock", "fresh identifier", "Random numbers", "user defaults", "keychain", "file", "locale", "network response"];

/** The chip grid: four columns, a row above the world and a row below it. */
const GRID = { cols: [360, 760, 1160, 1560], rows: [450, 890], w: 300, h: 60 } as const;
const slot = (i: number): Pt => [GRID.cols[i % 4], GRID.rows[Math.floor(i / 4)]];

/** "The world": overlapping puffs about a centre. Strands end on the inner ellipse, under the puffs. */
const WORLD = { x: 960, y: 670, rx: 230, ry: 105 } as const;
const PUFFS: [number, number, number][] = [
  [-180, 15, 85],
  [-95, -35, 95],
  [15, -45, 95],
  [130, -30, 90],
  [200, 25, 75],
  [90, 50, 85],
  [-40, 50, 90],
  [-150, 55, 60],
];

/** Where the ray from a w×h rectangle's centre toward `to` leaves the rectangle. */
function rectExit(c: Pt, w: number, h: number, to: Pt): Pt {
  const dx = to[0] - c[0];
  const dy = to[1] - c[1];
  const t = Math.min(dx === 0 ? Infinity : w / 2 / Math.abs(dx), dy === 0 ? Infinity : h / 2 / Math.abs(dy));
  return [c[0] + dx * t, c[1] + dy * t];
}

/** Where the ray from `from` toward the world's centre crosses its inner ellipse. */
function worldEntry(from: Pt): Pt {
  const dx = from[0] - WORLD.x;
  const dy = from[1] - WORLD.y;
  const k = 1 / Math.sqrt((dx / WORLD.rx) ** 2 + (dy / WORLD.ry) ** 2);
  return [WORLD.x + dx * k, WORLD.y + dy * k];
}

/** Geometry of a `CodeCard` (shared.tsx): its height, a column's x and a line's centre y. */
const card = (size: number, n: number) => ({
  h: 52 + n * size * 1.55 + 36,
  col: (left: number, c: number) => left + 27 + c * size * MONO_ADVANCE,
  line: (top: number, i: number) => top + 73 + (i + 0.5) * size * 1.55,
});

// The Cart initializer, recalled small at the top left.
const INIT = { left: 80, top: 130, w: 580, size: 22 } as const;
const INIT_LINES = ["init(", "    newOrderID: @escaping () -> UUID,", "    clock: @escaping () -> Date", ")"];
const INIT_GEOM = card(INIT.size, INIT_LINES.length);

// CartMigrationSpec.swift, lines 48–50.
const CART_LINES = [
  "// A receipt's order ID and timestamp, held still per capture.",
  ".provides((() -> UUID).self) { _ in Minted.identifiers() }",
  ".provides((() -> Date).self) { _ in { Minted.instant } }",
];
const CART = { w: 1140, size: 28 } as const;

// FulfillmentMigrationSpec.swift, lines 45 and 53.
const FULFIL_LINES = [".provides((() -> Date).self) { context in { StoreClock.now(context) } }", "…", 'Seam("Clock.now", .oneOf(StoreClock.instants))'];
const FULFIL = { w: 1280, size: 28, y: 490 } as const;
const FULFIL_GEOM = card(FULFIL.size, FULFIL_LINES.length);
const FULFIL_TOP = FULFIL.y - FULFIL_GEOM.h / 2;
const CLOCK_NOW: Pt = [FULFIL_GEOM.col(960 - FULFIL.w / 2, 10.5), FULFIL_GEOM.line(FULFIL_TOP, 2)];

/** The eight instants the planner's clock visits; two named, six stand-ins. */
type Instant = { text?: string; label?: string; lit?: "saturday" | "holiday" | "holiday2" };
const INSTANTS: Instant[] = [
  {},
  {},
  { text: "2026-10-03T16:00:00Z", label: "Saturday", lit: "saturday" },
  {},
  {},
  { text: "2026-07-03T12:00:00Z", label: "July 4 weekend", lit: "holiday2" },
  { text: "2026-12-24T22:00:00Z", label: "Christmas Eve", lit: "holiday" },
  {},
];
const FAN = { y: 740, h: 50, gap: 28, named: 350, small: 90, labelY: 803 } as const;
const FAN_W = INSTANTS.map((i) => (i.text ? FAN.named : FAN.small));
const FAN_X = (() => {
  const total = FAN_W.reduce((a, b) => a + b, 0) + FAN.gap * (INSTANTS.length - 1);
  let cursor = 960 - total / 2;
  return FAN_W.map((w) => {
    const c = cursor + w / 2;
    cursor += w + FAN.gap;
    return c;
  });
})();
const FAN_ORIGIN: Pt = [CLOCK_NOW[0], FULFIL_TOP + FULFIL_GEOM.h + 4];

const RECORDERS = "SeamClock · SeamRNG · SeamDefaults · SeamKeychain · SeamFileSystem · SeamEnvironment · CassetteURLProtocol";

const tint = (base: string, a: string) => `linear-gradient(${ROLE.seam}${a}, ${ROLE.seam}${a}), ${base}`;

/** An empty dashed slot the value chip will fill. */
const Slot: React.FC<{ at: Pt; show: number; out: number }> = ({ at: [x, y], show, out }) => {
  const o = useAppear(show, out, 0.4);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x - GRID.w / 2,
        top: y - GRID.h / 2,
        width: GRID.w,
        height: GRID.h,
        boxSizing: "border-box",
        borderRadius: 999,
        border: `2.5px dashed ${C.dim}55`,
        opacity: o,
      }}
    />
  );
};

/** A value the code reads from the world: a teal pill. */
const ValueChip: React.FC<{ at: Pt; label: string; show: number; out: number; dim: number; glow: number }> = ({ at: [x, y], label, show, out, dim, glow }) => {
  const o = useAppear(show, out, 0.4);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x - GRID.w / 2,
        top: y - GRID.h / 2,
        width: GRID.w,
        height: GRID.h,
        boxSizing: "border-box",
        borderRadius: 999,
        border: `2.5px solid ${ROLE.seam}`,
        background: tint(C.bg, "22"),
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: FONT.serif,
        fontSize: 30,
        color: ROLE.seam,
        whiteSpace: "nowrap",
        opacity: o * mix(1, 0.35, dim),
        transform: `scale(${mix(0.85, 1, o)})`,
        boxShadow: glow > 0 ? `0 0 ${28 * glow}px ${ROLE.seam}` : "none",
      }}
    >
      {label}
    </div>
  );
};

/** A thin grey strand from a chip to the world; it draws on, and can pull back into the chip. */
const Strand: React.FC<{ from: Pt; to: Pt; at: number; retract?: number; out: number; opacity?: number }> = ({ from, to, at, retract, out, opacity = 1 }) => {
  const { frame, fps } = useScene();
  const d = prog(frame, at, 0.6, fps) * (retract === undefined ? 1 : 1 - prog(frame, retract, 0.45, fps));
  const o = visibility(frame, fps, undefined, out) * opacity;
  if (d <= 0.001 || o <= 0) return null;
  return <line x1={from[0]} y1={from[1]} x2={mix(from[0], to[0], d)} y2={mix(from[1], to[1], d)} stroke={C.dim} strokeWidth={2} strokeLinecap="round" opacity={o} />;
};

/** A teal ring that lights a token in a code card. `x`/`y` are its centre. */
const Ring: React.FC<{ x: number; y: number; w: number; h: number; show: number; out?: number; pulse?: boolean; opacity?: number }> = ({
  x,
  y,
  w,
  h,
  show,
  out,
  pulse = false,
  opacity = 1,
}) => {
  const { frame, fps } = useScene();
  const o = useAppear(show, out, 0.4) * opacity;
  if (o <= 0) return null;
  const glow = pulse ? 0.5 + 0.5 * Math.sin(((frame - show) / fps) * Math.PI * 2 * 0.8) : 0.5;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        boxSizing: "border-box",
        borderRadius: 7,
        border: `2.5px solid ${ROLE.seam}`,
        background: `${ROLE.seam}26`,
        boxShadow: `0 0 ${20 * glow}px ${ROLE.seam}`,
        opacity: o,
      }}
    />
  );
};

/** A side of the check receiving the spec's values: a role-coloured box with its role. */
const SideBox: React.FC<{ x: number; color: string; label: string; show: number; out: number }> = ({ x, color, label, show, out }) => {
  const o = useAppear(show, out);
  if (o <= 0) return null;
  const w = 720;
  const h = 230;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: 835 - h / 2,
        width: w,
        height: h,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${color}`,
        background: `linear-gradient(180deg, ${color}1C, ${color}08)`,
        opacity: o,
        transform: `scale(${mix(0.94, 1, o)})`,
      }}
    >
      <div style={{ position: "absolute", left: 24, top: 10, fontFamily: FONT.serif, fontSize: 30, color }}>{label}</div>
    </div>
  );
};

/** A value in code form: a teal-bordered mono chip. `x`/`y` are its centre. */
const MonoChip: React.FC<{ x: number; y: number; text: string; opacity: number }> = ({ x, y, text, opacity }) =>
  opacity <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translate(-50%, -50%)",
        fontFamily: FONT.mono,
        fontSize: 26,
        lineHeight: "38px",
        color: C.text,
        border: `2.5px solid ${ROLE.seam}`,
        borderRadius: 12,
        padding: "4px 16px",
        background: tint(C.surface, "22"),
        whiteSpace: "nowrap",
        opacity,
      }}
    >
      {text}
    </div>
  );

/** One of the instants the clock is swept over. Named ones show their date; the rest are stand-ins. */
const DateChip: React.FC<{ x: number; y: number; w: number; text?: string; scale: number; opacity: number; lit: number }> = ({ x, y, w, text, scale, opacity, lit }) =>
  opacity <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - FAN.h / 2,
        width: w,
        height: FAN.h,
        boxSizing: "border-box",
        borderRadius: 999,
        border: `2.5px solid ${ROLE.seam}`,
        background: tint(C.surface, lit > 0 ? Math.round(0x22 + lit * 0x24).toString(16) : "22"),
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: FONT.mono,
        fontSize: 26,
        color: text ? C.text : C.dim,
        whiteSpace: "nowrap",
        opacity: opacity * mix(0.75, 1, lit),
        transform: `scale(${scale})`,
        boxShadow: lit > 0 ? `0 0 ${30 * lit}px ${ROLE.seam}` : "none",
      }}
    >
      {text ?? "…"}
    </div>
  );

export const Values: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  // Phase 1: the values, and the world they come from.
  const valuesAt = cue("Values are seams");
  const chipAt = VALUE_CUES.map((c) => cue(c));
  const readsAt = cue("reads from the world");
  const worldAt = cue("the world");
  // Phase 2: through the initializer.
  const throughAt = cue("through the initializer");
  const initAt = cue("initializer");
  const clearAt = cue("let the spec");
  // Phase 3: the cart's spec provides both sides the same values.
  const cartAt = cue("This cart's spec");
  const bothAt = cue("both sides");
  const seqAt = cue("sequential identifiers");
  const instAt = cue("one fixed instant");
  // Phase 4: a source that reads through the spec's seams, swept.
  const orAt = cue("Or provide");
  const throughSeamsAt = cue("reads through");
  const seamsAt = cue("spec's seams");
  const valueAt = cue("Then the value");
  const words = [
    { text: "recorded", at: cue("recorded") },
    { text: "replayed", at: cue("replayed") },
    { text: "swept", at: cue("swept") },
  ];
  const clockAt = cue("planner's clock");
  const eightAt = cue("eight instants");
  const litAt = { saturday: cue("Saturday"), holiday: cue("two holidays"), holiday2: cue("two holidays") + s(0.3) };
  // Phase 5: the ready-made recorders.
  const harnessAt = cue("a harness");
  const shipsAt = cue("Haruspec also ships");

  const focus = prog(frame, initAt, 0.5, fps);
  const cloud = prog(frame, readsAt, 0.6, fps) * visibility(frame, fps, undefined, clearAt);

  const initTop = INIT.top;
  const initCol = (c: number) => INIT_GEOM.col(INIT.left, c);
  const initLine = (i: number) => INIT_GEOM.line(initTop, i);

  const cartY = track(frame, fps, [
    [0, 490],
    [orAt + s(0.3), 245],
  ]);
  const cartDim = track(frame, fps, [
    [0, 0],
    [orAt + s(0.3), 0.55],
    [harnessAt, 0.75],
  ]);
  const fulfilY = track(frame, fps, [
    [0, FULFIL.y + 70],
    [throughSeamsAt, FULFIL.y],
  ]);
  const late = 1 - 0.45 * prog(frame, harnessAt, 0.6, fps);

  // The spec's values fork from below the card into both sides.
  const fork = (t: number, y: number, side: number) => ({
    x: track(frame, fps, [
      [0, 960],
      [t + s(0.45), side],
    ]),
    y: track(frame, fps, [
      [0, 655],
      [t + s(0.45), y],
    ]),
    o: prog(frame, t, 0.35, fps) * visibility(frame, fps, undefined, orAt),
  });

  // The eight instants fan out from Clock.now.
  const fanP = (i: number) => prog(frame, eightAt + s(i * 0.07), 0.7, fps);
  const fanPos = (i: number): Pt => [mix(FAN_ORIGIN[0], FAN_X[i], fanP(i)), mix(FAN_ORIGIN[1], FAN.y, fanP(i))];
  const lit = (i: number) => {
    const key = INSTANTS[i].lit;
    return key ? prog(frame, litAt[key], 0.4, fps) : 0;
  };

  return (
    <>
      {/* Phase 1: strands to the world, under the puffs; the puffs; the chips on top. */}
      <Svg>
        {VALUES.map((_, i) => {
          const c = slot(i);
          const to = worldEntry(c);
          return (
            <Strand
              key={i}
              from={rectExit(c, GRID.w, GRID.h, to)}
              to={to}
              at={readsAt + s(0.2 + i * 0.07)}
              retract={i < 2 ? initAt : undefined}
              out={clearAt}
              opacity={i < 2 ? 1 : mix(1, 0.35, focus)}
            />
          );
        })}
        {cloud > 0 && (
          <g opacity={cloud}>
            {PUFFS.map(([dx, dy, r], i) => (
              <circle key={i} cx={WORLD.x + dx} cy={WORLD.y + dy} r={r * mix(0.9, 1, cloud)} fill={C.faint} />
            ))}
          </g>
        )}
      </Svg>
      <Text x={WORLD.x} y={WORLD.y + 4} size={36} italic color={C.dim} at={worldAt} out={clearAt} dur={0.6}>
        the world
      </Text>
      {VALUES.map((v, i) => (
        <React.Fragment key={v}>
          <Slot at={slot(i)} show={valuesAt + s(i * 0.08)} out={clearAt} />
          <ValueChip at={slot(i)} label={v} show={chipAt[i]} out={clearAt} dim={i < 2 ? 0 : focus} glow={i < 2 ? focus * 0.6 : 0} />
        </React.Fragment>
      ))}

      {/* Phase 2: the Cart initializer returns, its two value parameters lit; clock and identifier re-route into them. */}
      <CodeCard
        x={INIT.left + INIT.w / 2}
        y={initTop + INIT_GEOM.h / 2}
        w={INIT.w}
        file="SubjectBoundaries.swift"
        lines={INIT_LINES}
        color={C.dim}
        size={INIT.size}
        at={throughAt}
        out={orAt}
      />
      <Text x={INIT.left + INIT.w - 24} y={initTop + 29} size={26} italic color={C.dim} anchor="right" at={throughAt + s(0.3)} out={orAt} reveal="fade">
        simplified
      </Text>
      <Ring x={(initCol(4) + initCol(14)) / 2} y={initLine(1)} w={(14 - 4) * INIT.size * MONO_ADVANCE + 12} h={30} show={throughAt + s(0.5)} out={orAt} />
      <Ring x={(initCol(4) + initCol(9)) / 2} y={initLine(2)} w={(9 - 4) * INIT.size * MONO_ADVANCE + 12} h={30} show={throughAt + s(0.5)} out={orAt} />
      <Svg>
        <Arrow from={[420, slot(0)[1] - GRID.h / 2 - 2]} to={[initCol(31) + 18, initLine(2) + 4]} at={initAt + s(0.3)} out={clearAt} dur={0.6} color={ROLE.seam} width={3} />
        <Arrow from={[730, slot(1)[1] - GRID.h / 2 - 2]} to={[initCol(37) + 10, initLine(1) + 2]} at={initAt + s(0.45)} out={clearAt} dur={0.6} color={ROLE.seam} width={3} />
      </Svg>

      {/* Phase 3: the cart's spec hands both sides the same identifiers and instant. */}
      <CodeCard
        x={960}
        y={cartY}
        w={CART.w}
        file="CartMigrationSpec.swift"
        lines={CART_LINES}
        color={C.text}
        size={CART.size}
        at={cartAt}
        dim={cartDim}
        marks={[
          { line: 1, at: seqAt, color: ROLE.seam },
          { line: 2, at: instAt, color: ROLE.seam },
        ]}
      />
      <SideBox x={STAGE.baseline} color={ROLE.baseline} label="baseline" show={bothAt} out={orAt} />
      <SideBox x={STAGE.candidate} color={ROLE.candidate} label="candidate" show={bothAt + s(0.15)} out={orAt} />
      {[STAGE.baseline, STAGE.candidate].map((side) => {
        const id = fork(seqAt, 812, side);
        const instant = fork(instAt, 882, side);
        return (
          <React.Fragment key={side}>
            <MonoChip x={id.x} y={id.y} text="00000000-0000-0000-0000-000000000001" opacity={id.o} />
            <MonoChip x={instant.x} y={instant.y} text="2026-09-21T14:13:20Z" opacity={instant.o} />
          </React.Fragment>
        );
      })}

      {/* Phase 4: a source that reads through the spec's seams; the clock swept over eight instants. */}
      <Svg>
        {INSTANTS.map((_, i) => {
          const p = fanP(i);
          if (p <= 0) return null;
          const [x, y] = fanPos(i);
          return (
            <line
              key={i}
              x1={FAN_ORIGIN[0]}
              y1={FAN_ORIGIN[1]}
              x2={x}
              y2={y - (FAN.h / 2) * p}
              stroke={ROLE.seam}
              strokeWidth={2}
              opacity={Math.min(1, p * 2) * mix(0.3, 0.8, lit(i)) * late}
            />
          );
        })}
      </Svg>
      <CodeCard
        x={960}
        y={fulfilY}
        w={FULFIL.w}
        file="FulfillmentMigrationSpec.swift"
        lines={FULFIL_LINES}
        color={C.text}
        size={FULFIL.size}
        at={throughSeamsAt}
        dim={1 - late}
        marks={[
          { line: 0, at: seamsAt, color: ROLE.seam },
          { line: 2, at: valueAt, color: ROLE.seam },
        ]}
      />
      {words.map((w, i) => (
        <Text key={w.text} x={1630} y={450 + i * 50} size={30} color={ROLE.seam} anchor="left" at={w.at} out={harnessAt} dur={0.4}>
          {w.text}
        </Text>
      ))}
      <Ring x={CLOCK_NOW[0]} y={CLOCK_NOW[1]} w={9 * FULFIL.size * MONO_ADVANCE + 14} h={40} show={clockAt} pulse opacity={late} />
      {INSTANTS.map((inst, i) => {
        const p = fanP(i);
        const [x, y] = fanPos(i);
        return (
          <DateChip key={i} x={x} y={y} w={FAN_W[i]} text={inst.text} scale={mix(0.3, 1, p)} opacity={Math.min(1, p * 2) * late} lit={lit(i)} />
        );
      })}
      {INSTANTS.map((inst, i) =>
        inst.label && inst.lit ? (
          <Text key={inst.label} x={FAN_X[i]} y={FAN.labelY} size={28} color={C.text} at={litAt[inst.lit]} dur={0.4} style={{ opacity: late }}>
            {inst.label}
          </Text>
        ) : null,
      )}
      <Text x={FAN_X[0] - FAN.small / 2} y={FAN.labelY} size={26} italic color={C.dim} anchor="left" at={eightAt + s(1)} reveal="fade" style={{ opacity: late }}>
        five more, elided
      </Text>

      {/* Phase 5: the ready-made recorders, for a harness you write yourself. */}
      <Svg>
        <Line from={[200, 858]} to={[1720, 858]} at={harnessAt} dur={0.8} color={C.faint} width={2} />
      </Svg>
      <Text x={960} y={902} size={26} font="mono" color={C.dim} at={harnessAt + s(0.2)} dur={1.8} maxWidth={1760}>
        {RECORDERS}
      </Text>
      <Fade x={960} y={952} anchor="center" at={shipsAt} rise={8}>
        <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, color: C.dim, whiteSpace: "nowrap" }}>
          <span style={{ fontFamily: FONT.mono, fontStyle: "normal" }}>HaruspecSeams</span> · on a{" "}
          <span style={{ fontFamily: FONT.mono, fontStyle: "normal" }}>Cassette</span> you hold
        </div>
      </Fade>
    </>
  );
};
