import React from "react";
import { useScene, Arrow, Fade, Svg, Text, C, FONT, prog } from "#kit";
import { CodeCard, ROLE, TraceStrip, useAppear } from "./shared";

// CartManager.h is simplified (initializers and other members omitted; the long selector wraps at its
// colon, Objective-C style). The spec is CartMigrationSpec.swift's block from
// example-xcode-migration/LegacyAppTests, with its comments and trailing modifiers removed.

const HEADER = [
  "@interface CartManager : NSObject",
  "- (void)addProduct:(Product *)product",
  "          quantity:(NSInteger)quantity;",
  "- (void)removeSku:(NSString *)sku;",
  "- (BOOL)applyPromo:(NSString *)code;",
  "- (Receipt *)checkout;",
  "@end",
];

const SPEC = [
  "Spec<Cart> {",
  '    Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))',
  '    Amend("removeSku").varying("sku", over: .oneOf(Catalog.skus))',
  '    Amend("checkout").last()',
  "}",
];

const TRACE = ["call addProduct", "call applyPromo", "call checkout"];

/** A grey card naming the usual way of testing, struck through and faded from `strikeAt`. */
const UsualCard: React.FC<{ y: number; text: string; at: number; strikeAt: number }> = ({ y, text, at, strikeAt }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, strikeAt + Math.round(0.9 * fps), 0.45);
  if (o <= 0) return null;
  const strike = prog(frame, strikeAt, 0.4, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: 960 - 260,
        top: y - 34,
        width: 520,
        height: 68,
        boxSizing: "border-box",
        borderRadius: 14,
        border: `2.5px solid ${C.dim}`,
        background: C.surface,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: FONT.serif,
        fontSize: 32,
        color: C.text,
        opacity: o,
        transform: `translateY(${(1 - Math.min(1, o)) * 12}px)`,
      }}
    >
      {text}
      <div style={{ position: "absolute", left: 24, top: "50%", height: 4, width: `calc(${strike} * (100% - 48px))`, background: ROLE.diverged }} />
    </div>
  );
};

/** A chip floating near the spec: something the three lines don't say. */
const Ghost: React.FC<{ x: number; y: number; text: string; at: number; drift: number }> = ({ x, y, text, at, drift }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.6);
  if (o <= 0) return null;
  const bob = Math.sin(((frame - at) / fps) * 1.6 + drift) * 6;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y + bob,
        transform: "translate(-50%, -50%)",
        fontFamily: FONT.mono,
        fontSize: 28,
        color: C.dim,
        border: `2.5px dashed ${C.dim}`,
        borderRadius: 999,
        padding: "6px 22px",
        opacity: o * 0.9,
        whiteSpace: "nowrap",
      }}
    >
      {text}
    </div>
  );
};

export const ThreeLines: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const cart = cue("shopping cart");
  const port = cue("Swift port");
  const totals = cue("expected totals");
  const mocks = cue("mocks");
  const assertion = cue("one assertion per path");
  const dont = cue("you don't");
  const oracle = cue("the expected value");
  const inputs = cue("the same inputs");
  const spec = cue("a spec");
  const three = cue("three lines");
  const everything = cue("everything else");

  // The input dots: eight dots fall from the top centre and split, alternately, into the two files.
  const dots = Array.from({ length: 8 }, (_, i) => {
    const start = inputs + s(i * 0.12);
    const p = prog(frame, start, 0.9, fps);
    if (frame < start || p >= 1) return null;
    const side = i % 2 === 0 ? 490 : 1430;
    const x = 960 + (side - 960) * p;
    const y = 120 + (230 - 120) * p;
    return <circle key={i} cx={x} cy={y} r={9} fill={ROLE.seam} opacity={1 - p * 0.4} />;
  });

  return (
    <>
      <CodeCard x={490} y={410} w={820} file="CartManager.h" lines={HEADER} color={ROLE.baseline} at={cart} out={spec} />
      <Text x={490} y={150} size={28} italic color={C.dim} at={cart + s(0.6)} out={spec} reveal="fade">
        the original · Objective-C
      </Text>
      <CodeCard x={1430} y={309} w={820} file="SwiftCart.swift" color={ROLE.candidate} at={port} out={spec} empty="the port" />
      <Text x={1430} y={150} size={28} italic color={C.dim} at={port + s(0.4)} out={spec} reveal="fade">
        the new Swift port
      </Text>

      <UsualCard y={720} text="expected values" at={totals} strikeAt={dont} />
      <UsualCard y={800} text="mocks" at={mocks} strikeAt={dont + s(0.15)} />
      <UsualCard y={880} text="one assertion per path" at={assertion} strikeAt={dont + s(0.3)} />

      <Fade x={760} y={232} anchor="center" at={oracle} out={spec} rise={8}>
        <div
          style={{
            fontFamily: FONT.mono,
            fontSize: 26,
            color: ROLE.baseline,
            border: `2.5px solid ${ROLE.baseline}`,
            borderRadius: 999,
            padding: "2px 16px",
            background: C.surface,
          }}
        >
          the oracle
        </div>
      </Fade>

      <Svg>{dots}</Svg>
      <TraceStrip x={200} y={660} rows={TRACE} color={ROLE.baseline} at={inputs + s(0.9)} out={spec} w={520} size={28} />
      <TraceStrip x={1140} y={660} rows={TRACE} color={ROLE.candidate} at={inputs + s(0.9)} out={spec} w={520} size={28} />
      <Svg>
        {[0, 1, 2].map((i) => (
          <Arrow key={i} from={[760, 680 + i * 42]} to={[1110, 680 + i * 42]} at={inputs + s(1.5 + i * 0.15)} out={spec} dur={0.4} color={ROLE.equivalent} head={false} dashed width={2} />
        ))}
      </Svg>
      <Text x={935} y={630} size={28} color={ROLE.equivalent} at={inputs + s(1.9)} out={spec} reveal="fade">
        compared
      </Text>

      {/* The spec: what you write instead. The originals shrink to name chips at the top. */}
      <Fade x={490} y={170} anchor="center" at={spec + s(0.3)} rise={0}>
        <div style={{ fontFamily: FONT.mono, fontSize: 26, color: ROLE.baseline, border: `2.5px solid ${ROLE.baseline}`, borderRadius: 999, padding: "4px 18px" }}>CartManager.h</div>
      </Fade>
      <Fade x={1430} y={170} anchor="center" at={spec + s(0.3)} rise={0}>
        <div style={{ fontFamily: FONT.mono, fontSize: 26, color: ROLE.candidate, border: `2.5px solid ${ROLE.candidate}`, borderRadius: 999, padding: "4px 18px" }}>SwiftCart.swift</div>
      </Fade>
      <CodeCard
        x={960}
        y={560}
        w={1520}
        file="CartMigrationSpec.swift"
        lines={SPEC}
        color={C.text}
        size={28}
        at={spec + s(0.4)}
        marks={[1, 2, 3].map((line, i) => ({ line, at: three + s(i * 0.15), color: ROLE.seam }))}
      />
      <Text x={960} y={760} size={30} italic color={ROLE.seam} at={three} reveal="fade">
        the heart of it: three lines
      </Text>

      <Ghost x={330} y={330} text="operations?" at={everything} drift={0} />
      <Ghost x={1590} y={330} text="values?" at={everything + s(0.2)} drift={1.3} />
      <Ghost x={330} y={860} text="effects?" at={everything + s(0.4)} drift={2.6} />
      <Ghost x={1590} y={860} text="which build?" at={everything + s(0.6)} drift={3.9} />
    </>
  );
};
