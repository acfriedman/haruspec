import React from "react";
import { useScene, Svg, Box, Arrow, Line, Text, C, FONT, MONO_ADVANCE, mix, prog, track } from "#kit";
import { ROLE, VERDICT, Verdict, TraceStrip } from "./shared";

// The trace rows are illustrative, not from a real run. The exit codes are the CLI's
// (Sources/CLI/main.swift, carried by VERDICT in shared.tsx); 6 is an otherwise-green run whose
// declared change matched nothing, so it is drawn apart from the four verdicts.

/** Pill lanes, top to bottom, once all four verdicts exist. */
const LANE = { unstable: 280, equivalent: 410, cannotVerify: 540, diverged: 670 } as const;
/** The diff box, centre and size. */
const DIFF = { x: 430, y: 540, w: 130, h: 100 };
/** Where pills rest: out of the diff, past coverage, past stability. */
const STOP = { a: 680, b: 1150, c: 1630 };
/** The two layers, as vertical columns the pills cross left to right. */
const BAND = { coverage: 910, stability: 1390, w: 70, top: 340, bottom: 735 };
const PILL = 32;
const ROWS = ["add(qty: 2)", "read price", "→ 1998"];
const STRIP = { x: 80, w: 220, blue: 320, pink: 600, mid: 77 };

type ChipSpec = { n: number; label: string; color: string; text?: string; apart?: boolean };
const CHIP = { size: 28, padX: 18, gap: 24, apart: 64, y: 900 };
const CHIPS: ChipSpec[] = [
  { n: VERDICT.equivalent.exit, label: VERDICT.equivalent.text, color: VERDICT.equivalent.color },
  { n: VERDICT.diverged.exit, label: VERDICT.diverged.text, color: VERDICT.diverged.color },
  { n: VERDICT.cannotVerify.exit, label: VERDICT.cannotVerify.text, color: VERDICT.cannotVerify.color },
  { n: VERDICT.unstable.exit, label: VERDICT.unstable.text, color: VERDICT.unstable.color },
  { n: 6, label: "declared, never observed", color: ROLE.diverged, text: C.dim, apart: true },
];
const chipW = (c: ChipSpec) => `${c.n} ${c.label}`.length * CHIP.size * MONO_ADVANCE + 2 * CHIP.padX + 6;
/** Each chip's centre x: the row is centred on the frame, with 6 set apart. */
const CHIP_X: number[] = (() => {
  const total = CHIPS.reduce((sum, c, i) => sum + chipW(c) + (i === 0 ? 0 : c.apart ? CHIP.apart : CHIP.gap), 0);
  let x = 960 - total / 2;
  return CHIPS.map((c, i) => {
    if (i > 0) x += c.apart ? CHIP.apart : CHIP.gap;
    const centre = x + chipW(c) / 2;
    x += chipW(c);
    return centre;
  });
})();

/** Wraps children in an opacity, so a pill dims without the shrink `Verdict`'s own `opacity` adds. */
const Dim: React.FC<{ o: number; children: React.ReactNode }> = ({ o, children }) => <div style={{ opacity: o }}>{children}</div>;

/** One layer: a soft column that grows from its middle, with caps top and bottom. Its sides stay
 *  faint so a pill resting in it stays legible. `hl` brightens it while the narration is on it;
 *  `tint` washes it in the colour of the abstention it produces. */
const Band: React.FC<{ x: number; at: number; hl: number; opacity: number; tint: number; tintColor: string }> = ({ x, at, hl, opacity, tint, tintColor }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const grow = prog(frame, at, 0.8, fps);
  const full = BAND.bottom - BAND.top;
  const h = full * grow;
  const mid = BAND.top + full / 2;
  const top = mid - h / 2;
  const left = x - BAND.w / 2;
  const capW = BAND.w + 24;
  const cap = mix(0.6, 1, hl) * opacity;
  return (
    <g opacity={Math.min(1, grow * 2)}>
      <rect x={left} y={top} width={BAND.w} height={h} fill={C.text} fillOpacity={(0.05 + 0.06 * hl) * opacity} />
      {tint > 0 && <rect x={left} y={top} width={BAND.w} height={h} fill={tintColor} fillOpacity={0.18 * tint * opacity} />}
      <line x1={left} y1={top} x2={left} y2={top + h} stroke={C.faint} strokeWidth={2} opacity={opacity} />
      <line x1={left + BAND.w} y1={top} x2={left + BAND.w} y2={top + h} stroke={C.faint} strokeWidth={2} opacity={opacity} />
      <line x1={x - capW / 2} y1={top} x2={x + capW / 2} y2={top} stroke={hl > 0.5 ? C.text : C.dim} strokeWidth={4} strokeLinecap="round" opacity={cap} />
      <line x1={x - capW / 2} y1={top + h} x2={x + capW / 2} y2={top + h} stroke={hl > 0.5 ? C.text : C.dim} strokeWidth={4} strokeLinecap="round" opacity={cap} />
    </g>
  );
};

/** An exit-code chip: a rounded rectangle (not a pill, so it never reads as a verdict). */
const Chip: React.FC<{ c: ChipSpec; x: number; at: number; dim: number; glow: number }> = ({ c, x, at, dim, glow }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, 0.45, fps);
  const w = chipW(c);
  const ink = c.text ?? c.color;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: CHIP.y,
        width: w,
        boxSizing: "border-box",
        transform: `translateY(-50%) translateY(${(1 - p) * 14}px)`,
        border: `3px solid ${c.color}`,
        borderRadius: 12,
        background: c.apart ? "transparent" : `${c.color}1A`,
        padding: `8px ${CHIP.padX}px`,
        fontFamily: FONT.mono,
        fontSize: CHIP.size,
        lineHeight: `${CHIP.size * 1.4}px`,
        color: ink,
        whiteSpace: "nowrap",
        textAlign: "center",
        opacity: p * mix(1, 0.3, dim),
        boxShadow: glow > 0 ? `0 0 ${32 * glow}px ${c.color}` : "none",
      }}
    >
      <span style={{ fontWeight: 700 }}>{c.n}</span>
      {" "}
      {c.label}
    </div>
  );
};

export const FourVerdicts: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const under = cue("Underneath");
  const diff = cue("the diff");
  const matched = cue("matched");
  const didnt = cue("they didn't");
  const layers = cue("Two layers");
  const four = cue("four verdicts");
  const covFirst = cue("Coverage first");
  const hides = cue("never hides a divergence");
  const survives = cue("an equivalent survives");
  const behind = cue("stand behind it");
  const cannot = cue("becomes cannot verify");
  const stab = cue("Then stability");
  const identical = cue("identical inputs");
  const disagree = cue("disagree");
  const any = cue("any verdict becomes unstable");
  const unst = cue("unstable", { after: any });
  const each = cue("Each verdict");
  const exitCode = cue("exit code");
  const onlyZero = cue("Only zero is a pass");
  const chipAt = [cue("Zero for equivalent"), cue("three for diverged"), cue("four for cannot verify"), cue("five for unstable"), cue("six for a declared")];

  // Attention: the diff recedes once the layers speak; the layers recede once the exit codes do.
  const leftO = 1 - 0.6 * prog(frame, covFirst, 0.6, fps) - 0.2 * prog(frame, each, 0.6, fps);
  const bandO = 1 - 0.6 * prog(frame, each, 0.6, fps);
  const covHL = prog(frame, covFirst, 0.5, fps) * (1 - prog(frame, stab, 0.5, fps));
  const stabHL = prog(frame, stab, 0.5, fps) * (1 - prog(frame, each, 0.5, fps));
  const covTint = prog(frame, cannot, 0.5, fps) * (1 - prog(frame, stab, 0.5, fps));
  const stabTint = prog(frame, unst, 0.5, fps) * (1 - prog(frame, each, 0.5, fps));
  const pass = prog(frame, onlyZero, 0.6, fps);
  const others = 1 - 0.7 * pass;
  const pulse = (at: number) => (frame < at ? 0 : prog(frame, at, 0.3, fps) * (1 - prog(frame, at + s(1.2), 0.6, fps)));

  // Pill paths. The equivalent enters the coverage band and splits on "stand behind it": one copy
  // goes on green, the other waits in the band (faded) until it becomes cannot-verify.
  const T = 1.0;
  const eqX = track(frame, fps, [[0, 540], [matched, STOP.a], [survives, BAND.coverage], [behind, STOP.b], [any, STOP.c]], T);
  const eqY = track(frame, fps, [[0, DIFF.y], [matched, LANE.equivalent]], T);
  const divX = track(frame, fps, [[0, 540], [didnt, STOP.a], [hides, STOP.b], [any + s(0.4), STOP.c]], T);
  const divY = track(frame, fps, [[0, DIFF.y], [didnt, LANE.diverged]], T);
  const cvX = track(frame, fps, [[0, BAND.coverage], [cannot, STOP.b], [any + s(0.2), STOP.c]], T);
  const cvY = track(frame, fps, [[0, LANE.equivalent], [behind, LANE.cannotVerify]], T);
  // Unstable forks off the top of the stability band, clear of its label and the equivalent.
  const unX = track(frame, fps, [[0, BAND.stability - 40], [unst, STOP.c]], T);
  const unY = track(frame, fps, [[0, 355], [unst, LANE.unstable]], T);

  const label = (text: string, x: number, at: number, hl: number) => (
    <div style={{ opacity: bandO * mix(0.7, 1, hl) }}>
      <Text x={x} y={BAND.top - 40} size={32} italic color={C.text} at={at} reveal="fade">
        {text}
      </Text>
    </div>
  );

  return (
    <>
      {/* Underneath: two traces feed the diff. */}
      <TraceStrip x={STRIP.x} y={STRIP.blue} w={STRIP.w} rows={ROWS} color={ROLE.baseline} title="baseline" at={under} opacity={leftO} />
      <TraceStrip x={STRIP.x} y={STRIP.pink} w={STRIP.w} rows={ROWS} color={ROLE.candidate} title="candidate" at={under + s(0.3)} opacity={leftO} />
      <Svg opacity={leftO}>
        <Arrow from={[292, STRIP.blue + STRIP.mid]} to={[DIFF.x - DIFF.w / 2 - 8, DIFF.y - 28]} at={diff} dur={0.5} color={ROLE.baseline} width={3} />
        <Arrow from={[292, STRIP.pink + STRIP.mid]} to={[DIFF.x - DIFF.w / 2 - 8, DIFF.y + 28]} at={diff} dur={0.5} color={ROLE.candidate} width={3} />
        <Box x={DIFF.x} y={DIFF.y} w={DIFF.w} h={DIFF.h} at={diff} color={C.text} fill={C.surface} r={14} width={3} />
      </Svg>
      <div style={{ opacity: leftO }}>
        <Text x={DIFF.x} y={DIFF.y} size={34} font="mono" color={C.text} at={diff + s(0.2)} reveal="fade">
          diff
        </Text>
      </div>

      {/* The two layers, the four destinations, and the fork into unstable. */}
      <Svg>
        <Band x={BAND.coverage} at={layers} hl={covHL} opacity={bandO} tint={covTint} tintColor={ROLE.cannotVerify} />
        <Band x={BAND.stability} at={layers + s(0.3)} hl={stabHL} opacity={bandO} tint={stabTint} tintColor={ROLE.unstable} />
        {(["unstable", "equivalent", "cannotVerify", "diverged"] as const).map((k, i) => {
          const o = prog(frame, four + s(i * 0.12), 0.4, fps) * (1 - prog(frame, any, 0.5, fps));
          return frame >= four && o > 0 ? <circle key={k} cx={STOP.c} cy={LANE[k]} r={10} fill={VERDICT[k].color} opacity={o} /> : null;
        })}
        <Line from={[BAND.stability + BAND.w / 2 + 4, LANE.equivalent - 36]} to={[STOP.c - 136, LANE.unstable + 4]} at={unst + s(0.5)} out={each} dur={0.4} color={ROLE.unstable} width={3} dashed />
      </Svg>
      {label("coverage", BAND.coverage, layers, covHL)}
      {label("stability", BAND.stability, layers + s(0.3), stabHL)}

      {/* The pills. */}
      <Verdict x={eqX} y={eqY} kind="equivalent" at={matched} size={PILL} glow={Math.max(pulse(behind), pulse(chipAt[0]), 0.8 * pass)} />
      <Dim o={0.6}>
        <Verdict x={cvX} y={cvY} kind="equivalent" at={behind} out={cannot} size={PILL} />
      </Dim>
      <Dim o={others}>
        <Verdict x={cvX} y={cvY} kind="cannotVerify" at={cannot} size={PILL} glow={pulse(chipAt[2])} />
        <Verdict x={divX} y={divY} kind="diverged" at={didnt} size={PILL} glow={pulse(chipAt[1])} />
        <Verdict x={unX} y={unY} kind="unstable" at={unst} size={PILL} glow={pulse(chipAt[3])} />
      </Dim>

      <Text x={STOP.b} y={LANE.equivalent - 60} size={28} italic color={ROLE.equivalent} at={behind + s(0.5)} out={any} reveal="fade">
        coverage stands behind it
      </Text>
      <Text x={BAND.stability} y={BAND.bottom + 42} size={26} italic color={C.dim} at={identical} out={each} reveal="fade">
        same input
      </Text>
      <Text x={BAND.stability} y={BAND.bottom + 82} size={26} font="mono" color={ROLE.unstable} at={disagree} out={each} reveal="fade">
        run 1 ≠ run 2
      </Text>

      {/* Exit codes along the bottom, one per number as it is spoken; only zero passes. */}
      <Text x={CHIP_X[0] - chipW(CHIPS[0]) / 2} y={838} size={28} italic color={C.dim} anchor="left" at={exitCode} reveal="fade">
        exit code
      </Text>
      {CHIPS.map((c, i) => (
        <Chip key={c.n} c={c} x={CHIP_X[i]} at={chipAt[i]} dim={i === 0 ? 0 : pass} glow={i === 0 ? Math.max(pulse(chipAt[0]), pass) : pulse(chipAt[i])} />
      ))}
      <Text x={CHIP_X[0]} y={968} size={26} font="mono" color={C.dim} at={onlyZero + s(0.4)} reveal="fade">
        Sources/CLI/main.swift
      </Text>
    </>
  );
};
