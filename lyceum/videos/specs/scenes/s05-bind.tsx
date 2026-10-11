import React from "react";
import { useScene, Arrow, Line, Svg, Text, C, FONT, lin, mix, prog, smooth, track, visibility } from "#kit";
import { CodeCard, ROLE, Verdict, useAppear } from "./shared";

// The spec recall is the three-line spec with its amendment arguments elided ("simplified"), so it
// fits the left column at a legible size. The suite is CartMigrationSpec.swift's test suite from
// example-xcode-migration/LegacyAppTests, with its audit line and doc comments removed. The
// prefetcher check and the named spec are lines from the README.

const SPEC = [
  "Spec<Cart> {",
  '    Amend("applyPromo").varying(…)',
  '    Amend("removeSku").varying(…)',
  '    Amend("checkout").last()',
  "}",
];

// Blank lines hold a space so CodeCard gives them a full line's height.
const SUITE = [
  '@Suite("cart.objc-to-swift", .campaign)',
  "struct CartMigrationTests {",
  "    private let subject = CartMigrationSpec().baselined(on: CartManager.self)",
  " ",
  "    @Test func swiftPortIsIndistinguishableFromTheBaseline() async throws {",
  "        try await subject.check(SwiftCart.self)",
  "    }",
  " ",
  "    @Test func truncationBugStillDiverges() async throws {",
  "        try await subject.check(SwiftCartBuggy.self, expecting: .diverged)",
  "    }",
  "}",
];

// Layout (final positions; the left column and the flow sit 120 px higher until the suite arrives).
const SPEC_X = 410;
const SPEC_Y = 480;
const SPEC_W = 600;
const SPEC_SIZE = 26;
const SPEC_H = 52 + SPEC.length * SPEC_SIZE * 1.55 + 36;
/** The centre of the spec card's first line, and the left edge of its code. */
const SPEC_LINE0 = SPEC_Y - SPEC_H / 2 + 75 + (SPEC_SIZE * 1.55) / 2;
const SPEC_CODE_X = SPEC_X - SPEC_W / 2 + 27;
const ADV = SPEC_SIZE * 0.6;

const ROW = 715;
const START_X = 935;
const INIT_X = 1275;
const TRACED_X = 1670;
const INNER_Y = ROW + 22;

const SUITE_X = 1308;
const SUITE_Y = 370;
const SUITE_W = 1064;
const SUITE_SIZE = 22;

const clamp01 = (v: number) => Math.max(0, Math.min(1, v));

/** A rounded mono chip centred on `x`/`y`, on an opaque ground so it can travel over things. */
const Chip: React.FC<{
  x: number;
  y: number;
  color: string;
  children: React.ReactNode;
  size?: number;
  opacity?: number;
  scale?: number;
  glow?: number;
}> = ({ x, y, color, children, size = 26, opacity = 1, scale = 1, glow = 0 }) => {
  if (opacity <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) scale(${scale})`,
        fontFamily: FONT.mono,
        fontSize: size,
        lineHeight: 1.3,
        color,
        border: `2.5px solid ${color}`,
        borderRadius: 999,
        padding: `2px ${Math.round(size * 0.6)}px`,
        background: C.surface,
        opacity,
        whiteSpace: "nowrap",
        boxShadow: glow > 0 ? `0 0 ${32 * glow}px ${color}` : "none",
      }}
    >
      {children}
    </div>
  );
};

/** A rounded box centred on `x`/`y` with its contents centred inside. */
const Panel: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  color: string;
  opacity: number;
  scale?: number;
  glow?: number;
  glowColor?: string;
  children?: React.ReactNode;
}> = ({ x, y, w, h, color, opacity, scale = 1, glow = 0, glowColor, children }) => {
  if (opacity <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        boxSizing: "border-box",
        borderRadius: 14,
        border: `2.5px solid ${color}`,
        background: C.surface,
        opacity,
        transform: `scale(${scale})`,
        boxShadow: glow > 0 ? `0 0 ${36 * glow}px ${glowColor ?? color}` : "none",
      }}
    >
      {children}
    </div>
  );
};

/** A line of code in its own small panel, written on left to right from `at` over `dur` seconds. */
const CodeLine: React.FC<{ x: number; y: number; at: number; out?: number; dur?: number; dashed?: boolean; children: React.ReactNode }> = ({ x, y, at, out, dur = 0.9, dashed, children }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  const p = lin(frame, at + Math.round(0.15 * fps), dur, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: "translate(-50%, -50%)",
        opacity: o,
        border: `2.5px ${dashed ? "dashed" : "solid"} ${C.dim}`,
        borderRadius: 12,
        background: C.surface,
        padding: "8px 22px",
        fontFamily: FONT.mono,
        fontSize: 26,
        lineHeight: 1.4,
        whiteSpace: "pre",
        color: C.text,
      }}
    >
      <span style={{ display: "inline-block", clipPath: `inset(0 ${(1 - p) * 100}% 0 0)` }}>{children}</span>
    </div>
  );
};

/** A name the stamp gives: a chip with a short label to its right. `x` is its left edge. */
const NameChip: React.FC<{ x: number; y: number; at: number; color: string; label: string; children: React.ReactNode }> = ({ x, y, at, color, label, children }) => {
  const o = useAppear(at, undefined, 0.5);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x + (1 - o) * -16,
        top: y,
        transform: "translateY(-50%)",
        display: "flex",
        alignItems: "center",
        gap: 22,
        opacity: o,
        whiteSpace: "nowrap",
      }}
    >
      <span
        style={{
          fontFamily: FONT.mono,
          fontSize: 30,
          lineHeight: 1.3,
          color,
          border: `2.5px solid ${color}`,
          borderRadius: 999,
          padding: "2px 18px",
          background: C.surface,
        }}
      >
        {children}
      </span>
      <span style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 28, color: C.dim }}>{label}</span>
    </div>
  );
};

export const Bind: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const specNames = cue("The spec names");
  const noImpl = cue("no implementation");
  const protocol = cue("describes the protocol");
  const testChooses = cue("The test chooses");
  const baselined = cue("baselined on");
  const handIt = cue("Hand it");
  const origType = cue("original's type");
  const pasted = cue("the pasted initializer");
  const collab = cue("each collaborator");
  const resolved = cue("resolved for you");
  const wrapped = cue("wrapped in the forwarder");
  const forwarder = cue("forwarder");
  const thenEach = cue("Then each port");
  const oneCheck = cue("each port is one check");
  const byType = cue("by its type");
  const built = cue("built exactly");
  const portWhose = cue("A port whose");
  const ownInit = cue("its own initializer");
  const shouldRed = cue("A check that should");
  const expecting = cue("expecting diverged");
  const diverged = cue("diverged");
  const bites = cue("still bites");
  const andSpec = cue("And the spec's");
  const specsName = cue("spec's name");
  const stamp = cue("comes from the stamp");
  const reports = cue("reports");
  const plans = cue("plans");
  const nameEach = cue("name each");

  // The left column and the flow sit higher until the suite needs the top right, then settle down.
  const shift = track(frame, fps, [[0, -120], [thenEach, 0]], 0.8);
  // The spec card arrives large and centred, then shrinks into the left column.
  const shrink = prog(frame, specNames, 0.9, fps);
  // While the suite holds the stage the left column steps back; it returns for the name.
  const dimV = track(frame, fps, [[0, 0], [thenEach, 1], [andSpec, 0]], 0.6);
  const leftDim = mix(1, 0.4, dimV);

  // The slot: dashed and empty, then filled with the binding and turned baseline blue.
  const slotVis = (frame < noImpl ? 0 : prog(frame, noImpl, 0.5, fps)) * visibility(frame, fps, undefined, andSpec) * leftDim;
  const fill = prog(frame, baselined + s(0.6), 0.4, fps);
  const askO = 1 - prog(frame, baselined + s(0.2), 0.35, fps);
  const bp = prog(frame, baselined, 0.8, fps);
  const bindO = frame < baselined ? 0 : lin(frame, baselined, 0.25, fps);
  const typeGlow = frame >= origType ? Math.sin(Math.PI * lin(frame, origType, 0.8, fps)) : 0;

  // The test that chooses, before the suite is shown in full.
  const testO = useAppear(testChooses, handIt, 0.5) * (frame >= baselined ? mix(1, 0.5, prog(frame, baselined, 0.3, fps)) : 1);

  // The flow: the type handed over, through the initializer, into the forwarder.
  const flowOut = visibility(frame, fps, undefined, portWhose);
  const startP = prog(frame, origType, 0.7, fps);
  const startO = (frame < origType ? 0 : startP) * flowOut;
  const startX = mix(600, START_X, startP);
  const swap = prog(frame, byType, 0.5, fps);
  const initO = useAppear(pasted + s(0.4), portWhose, 0.5);
  const tracedO = useAppear(forwarder, portWhose, 0.5);
  const tracedScale = mix(1.12, 1, prog(frame, forwarder, 0.5, fps));
  // A run's dot reaches the forwarder's edge about 0.8 s after it leaves.
  const blueArrive = wrapped + s(0.8);
  const pinkArrive = built + s(0.8);
  const blueInner = frame < blueArrive ? 0 : prog(frame, blueArrive, 0.3, fps) * (1 - prog(frame, pinkArrive, 0.3, fps)) * flowOut;
  const pinkInner = frame < pinkArrive ? 0 : prog(frame, pinkArrive, 0.3, fps) * flowOut;

  // A type running the flow: a dot leaves the start chip, passes under the initializer (which glows
  // as it goes through) and into the forwarder, whose inner chip then shows the type.
  let initGlow = 0;
  let glowColor: string = C.text;
  const RUN = 1.2;
  const runs = [
    { at: wrapped, color: ROLE.baseline },
    { at: built, color: ROLE.candidate },
  ].map((r, i) => {
    if (frame < r.at) return null;
    const t = lin(frame, r.at, RUN, fps);
    if (t >= 1) return null;
    const x = mix(START_X + 110, TRACED_X, smooth(t));
    if (x > INIT_X - 155 && x < INIT_X + 155) {
      initGlow = Math.sin((Math.PI * (x - (INIT_X - 155))) / 310);
      glowColor = r.color;
    }
    return <circle key={i} cx={x} cy={ROW} r={11} fill={r.color} opacity={flowOut} />;
  });
  const arrivals = [
    { at: blueArrive, color: ROLE.baseline },
    { at: pinkArrive, color: ROLE.candidate },
  ];
  const landed = arrivals.filter((a) => frame >= a.at).at(-1);
  const tracedGlow = landed ? Math.sin(Math.PI * lin(frame, landed.at, 0.7, fps)) : 0;

  // Collaborators plug into the initializer from below.
  const collabs = [-1, 0, 1].map((d, i) => {
    const at = collab + s(i * 0.15);
    const o = frame < at ? 0 : prog(frame, at, 0.45, fps) * flowOut;
    if (o <= 0) return null;
    return (
      <div
        key={i}
        style={{
          position: "absolute",
          left: INIT_X + d * 95 - 35,
          top: 805 - 19 + (1 - o) * 30,
          width: 70,
          height: 38,
          boxSizing: "border-box",
          borderRadius: 10,
          border: `2.5px solid ${C.dim}`,
          background: `${C.dim}33`,
          opacity: o,
        }}
      />
    );
  });

  const pillGlow = frame >= bites && frame < bites + s(0.9) ? Math.sin(Math.PI * lin(frame, bites, 0.9, fps)) : 0;
  const ringO = useAppear(specsName, undefined, 0.4);
  const tagO = useAppear(stamp, undefined, 0.5);

  return (
    <>
      {/* The left column and the flow, raised until the suite arrives. */}
      <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, transform: `translateY(${shift}px)` }}>
        <div
          style={{
            position: "absolute",
            left: 0,
            top: 0,
            width: 1920,
            height: 1080,
            transformOrigin: `${SPEC_X}px ${SPEC_Y}px`,
            transform: `translate(${mix(550, 0, shrink)}px, ${mix(180, 0, shrink)}px) scale(${mix(1.3, 1, shrink)})`,
            opacity: leftDim,
          }}
        >
          <CodeCard x={SPEC_X} y={SPEC_Y} w={SPEC_W} file="CartMigrationSpec.swift" lines={SPEC} color={C.text} size={SPEC_SIZE} at={0} />
          <Text x={640} y={SPEC_Y - SPEC_H / 2 + 30} size={26} italic color={C.dim} at={s(0.4)} reveal="fade">
            simplified
          </Text>
        </div>

        <Svg>
          <Line from={[SPEC_CODE_X + 5 * ADV, SPEC_LINE0 + 19]} to={[SPEC_CODE_X + 9 * ADV, SPEC_LINE0 + 19]} at={protocol} out={testChooses} dur={0.4} color={C.text} width={3} />
          <Arrow from={[716, ROW]} to={[826, ROW]} at={origType + s(0.35)} out={thenEach} dur={0.4} color={C.dim} width={3} />
          <Arrow from={[1047, ROW]} to={[1112, ROW]} at={pasted} out={portWhose} dur={0.4} color={C.dim} width={3} />
          <Arrow from={[1437, ROW]} to={[1502, ROW]} at={wrapped} out={portWhose} dur={0.4} color={C.dim} width={3} />
          {[-1, 0, 1].map((d, i) => (
            <Line key={i} from={[INIT_X + d * 95, 786]} to={[INIT_X + d * 95, 749]} at={resolved + s(i * 0.1)} out={portWhose} dur={0.3} color={C.dim} width={3} />
          ))}
        </Svg>
        <Text x={430} y={SPEC_LINE0} size={26} italic color={C.dim} at={protocol + s(0.3)} out={testChooses} reveal="fade">
          the protocol
        </Text>

        {/* The slot beneath the spec: no implementation until the test binds one. */}
        {slotVis > 0 && (
          <>
            <div style={{ position: "absolute", left: SPEC_X - 300, top: ROW - 36, width: 600, height: 72, boxSizing: "border-box", borderRadius: 14, border: `2.5px dashed ${C.dim}`, opacity: slotVis * (1 - fill) }} />
            <div
              style={{
                position: "absolute",
                left: SPEC_X - 300,
                top: ROW - 36,
                width: 600,
                height: 72,
                boxSizing: "border-box",
                borderRadius: 14,
                border: `2.5px solid ${ROLE.baseline}`,
                background: `${ROLE.baseline}1E`,
                opacity: slotVis * fill,
              }}
            />
            <div
              style={{
                position: "absolute",
                left: SPEC_X,
                top: ROW,
                transform: "translate(-50%, -50%)",
                fontFamily: FONT.serif,
                fontStyle: "italic",
                fontSize: 28,
                color: C.dim,
                opacity: slotVis * askO,
                whiteSpace: "nowrap",
              }}
            >
              implementation?
            </div>
          </>
        )}

        {/* The test, which picks what to trust. */}
        <Chip x={1300} y={ROW} color={C.text} opacity={testO}>
          CartMigrationTests
        </Chip>
        <Text x={1300} y={ROW - 58} size={28} italic color={C.dim} at={testChooses + s(0.2)} out={handIt} reveal="fade">
          the test
        </Text>

        {/* The binding slides from the test into the slot. */}
        {bindO * slotVis > 0 && (
          <div
            style={{
              position: "absolute",
              left: mix(880, SPEC_X, bp),
              top: ROW,
              transform: "translate(-50%, -50%)",
              fontFamily: FONT.mono,
              fontSize: 26,
              color: C.text,
              whiteSpace: "pre",
              opacity: bindO * (bp < 1 ? 1 : slotVis),
            }}
          >
            {".baselined(on: "}
            <span style={{ color: ROLE.baseline, textShadow: typeGlow > 0 ? `0 0 ${20 * typeGlow}px ${ROLE.baseline}` : "none" }}>CartManager</span>
            {".self)"}
          </div>
        )}

        {/* The flow. */}
        <Svg>{runs}</Svg>
        <Chip x={startX} y={ROW} color={ROLE.baseline} opacity={startO * (1 - swap)}>
          CartManager
        </Chip>
        <Chip x={startX} y={ROW} color={ROLE.candidate} opacity={startO * swap}>
          SwiftCart
        </Chip>
        <Panel x={INIT_X} y={ROW} w={310} h={64} color={C.text} opacity={initO} glow={initGlow} glowColor={glowColor}>
          <div style={{ fontFamily: FONT.mono, fontSize: 26, color: C.text, lineHeight: "59px", textAlign: "center", whiteSpace: "nowrap" }}>init(inventory:…)</div>
        </Panel>
        {collabs}
        <Text x={INIT_X} y={862} size={26} italic color={C.dim} at={resolved} out={portWhose} reveal="fade">
          resolved · seams video
        </Text>
        <Panel x={TRACED_X} y={ROW} w={320} h={120} color={C.text} opacity={tracedO} scale={tracedScale} glow={tracedGlow} glowColor={landed?.color}>
          <div style={{ fontFamily: FONT.mono, fontSize: 26, color: C.text, textAlign: "center", marginTop: 12 }}>TracedCart</div>
        </Panel>
        <Text x={TRACED_X} y={805} size={26} italic color={C.dim} at={forwarder + s(0.2)} out={portWhose} reveal="fade">
          the forwarder
        </Text>
        <Chip x={TRACED_X} y={INNER_Y} color={ROLE.baseline} opacity={blueInner}>
          CartManager
        </Chip>
        <Chip x={TRACED_X} y={INNER_Y} color={ROLE.candidate} opacity={pinkInner}>
          SwiftCart
        </Chip>
      </div>

      {/* The suite: the test binds the baseline, and each port is one check. */}
      <CodeCard
        x={SUITE_X}
        y={SUITE_Y}
        w={SUITE_W}
        file="CartMigrationSpec.swift"
        lines={SUITE}
        color={C.text}
        size={SUITE_SIZE}
        at={oneCheck}
        out={andSpec}
        marks={[
          { line: 2, at: oneCheck + s(0.8), color: ROLE.baseline },
          { line: 5, at: byType, color: ROLE.candidate },
          ...[8, 9, 10].map((line) => ({ line, at: expecting, color: ROLE.diverged })),
        ]}
      />

      <CodeLine x={SUITE_X} y={700} at={ownInit} out={shouldRed}>
        {"try await subject.check("}
        <span style={{ color: ROLE.candidate }}>SwiftCatalogPrefetcher</span>
        {".init)"}
      </CodeLine>
      <Text x={SUITE_X} y={768} size={26} italic color={C.dim} at={ownInit + s(0.5)} out={shouldRed} reveal="fade">
        from the README
      </Text>

      <Verdict x={1290} y={685} kind="diverged" size={34} at={diverged} out={andSpec} glow={pillGlow} />
      <Text x={1530} y={685} size={28} italic color={C.dim} at={diverged + s(0.35)} out={andSpec} reveal="fade">
        expected
      </Text>

      {/* The name: derived from the stamp, and carried into reports and plans. */}
      {ringO > 0 && (
        <div
          style={{
            position: "absolute",
            left: SPEC_CODE_X - 8,
            top: SPEC_LINE0 - 21,
            width: 10 * ADV + 16,
            height: 42,
            boxSizing: "border-box",
            borderRadius: 8,
            border: `2.5px solid ${C.text}`,
            opacity: ringO,
          }}
        />
      )}
      {tagO > 0 && (
        <div
          style={{
            position: "absolute",
            left: mix(320, 340, tagO),
            top: SPEC_LINE0,
            transform: "translateY(-50%)",
            fontFamily: FONT.mono,
            fontSize: 26,
            lineHeight: 1.3,
            whiteSpace: "pre",
            border: `2.5px solid ${C.text}`,
            borderRadius: 999,
            padding: "1px 14px",
            background: C.surface,
            opacity: tagO,
          }}
        >
          <span style={{ color: C.dim }}>{"name: "}</span>
          <span style={{ color: C.text }}>"Cart"</span>
        </div>
      )}
      <Svg>
        <Arrow from={[574, SPEC_LINE0]} to={[886, SPEC_LINE0]} at={reports} dur={0.5} color={C.dim} width={3} />
        <Arrow from={[744, SPEC_LINE0]} to={[886, 545]} bend={-20} at={plans} dur={0.5} color={C.dim} width={3} />
      </Svg>
      <NameChip x={900} y={SPEC_LINE0} at={reports + s(0.2)} color={C.text} label="report title">
        Cart<span style={{ color: C.dim }}>/</span>
        <span style={{ color: ROLE.candidate }}>SwiftCart</span>
      </NameChip>
      <NameChip x={900} y={545} at={plans + s(0.2)} color={ROLE.plan} label="plan file">
        Cart.plan.json.gz
      </NameChip>

      <CodeLine x={SPEC_X} y={ROW} at={nameEach - s(0.15)} dur={0.6} dashed>
        <span style={{ color: C.dim }}>{"Spec<Cart>"}</span>
        {'("cart.promo")'}
        <span style={{ color: C.dim }}>{" { … }"}</span>
      </CodeLine>
      <Text x={SPEC_X} y={785} size={26} italic color={C.dim} at={nameEach + s(0.3)} reveal="fade">
        from the README
      </Text>
    </>
  );
};
