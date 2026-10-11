import React from "react";
import { useScene, Arrow, Line, Svg, C, FONT, prog, lin, mix, track } from "#kit";
import { CodeCard, ROLE, TraceStrip, useAppear } from "./shared";

// SubjectBoundaries.swift is simplified (initializer abridged, comments removed), labelled so in its
// header. The two conformance lines are real. The trace rows under TracedCart are illustrative values.
// The stamp generates three things, shown as chips in a neutral accent (C.text): adopter level, never
// how the macro expands.

const PROTOCOL = [
  "@Haruspec",
  "protocol Cart: AnyObject {",
  "    init(",
  "        inventory: InventoryReserving,",
  "        analytics: AnalyticsTracking,",
  "        notificationCenter: NotificationCenter,",
  "        …",
  "    )",
  "    func add(_ product: Product!, quantity: Int) async",
  "    func removeSku(_ sku: String!) async",
  "    func applyPromo(_ code: String!) async -> Bool",
  "    func checkout() async -> Receipt!",
  "    var itemCount: Int { get async }",
  "    var subtotalCents: Int { get async }",
  "}",
];

const CONFORMANCES = [
  { text: "extension CartManager: Cart {}", color: ROLE.baseline },
  { text: "extension SwiftCart: Cart {}", color: ROLE.candidate },
];

const TRACE = ['Cart.applyPromo · call · code: "SAVE10"', "Cart.applyPromo · return · true"];

// The protocol card, x 80–1000, top 124. CodeCard centres on y, so the centre follows the height.
const CARD = { x: 540, w: 920, top: 124, size: 26 };
const LH = CARD.size * 1.55;
const CARD_H = 52 + PROTOCOL.length * LH + 36;
const CARD_Y = CARD.top + CARD_H / 2;
const CODE_X = CARD.x - CARD.w / 2 + 3 + 24;
/** Where line `i` of the protocol card sits (border, header and its rule, body padding). */
const lineTop = (i: number) => CARD.top + 3 + 54 + 18 + i * LH;
const lineMid = (i: number) => lineTop(i) + LH / 2;

// The conformances card sits under the protocol card.
const EXT = { x: 80, top: 842, w: 560, pad: 14, gap: 8 };
const extMid = (i: number) => EXT.top + 3 + EXT.pad + i * (LH + EXT.gap) + LH / 2;

// The generated chips, x 1100–1560, fed by a trunk from the @Haruspec line and a spine at x 1040.
const TRUNK_Y = lineMid(0);
const SPINE_X = 1040;
const CHIP = { left: 1100, w: 460, h: 96 };
const CHIP_Y = { traced: TRUNK_Y, derived: 520, double: 730 };

/** A tint behind protocol lines `from`…`to`; drawn before the card, so it shows through its wash. */
const Band: React.FC<{ from: number; to: number; color: string; at: number; out?: number; alpha?: string }> = ({ from, to, color, at, out, alpha = "40" }) => {
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: CODE_X - 10,
        top: lineTop(from),
        width: CARD.w - 6 - 48 + 20,
        height: (to - from + 1) * LH,
        borderRadius: 8,
        background: `${color}${alpha}`,
        opacity: o,
      }}
    />
  );
};

/** The `@Haruspec` attribute, pressed onto line 0 like a stamp, with a glow (0…1). */
const StampLine: React.FC<{ at: number; glow: number }> = ({ at, glow }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, 0.35, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: CODE_X,
        top: lineTop(0),
        height: LH,
        lineHeight: `${LH}px`,
        fontFamily: FONT.mono,
        fontSize: CARD.size,
        whiteSpace: "pre",
        color: C.text,
        fontWeight: 700,
        opacity: p,
        transform: `scale(${mix(1.6, 1, p)})`,
        transformOrigin: "left center",
        textShadow: glow > 0 ? `0 0 ${20 * glow}px ${C.text}99` : "none",
      }}
    >
      @Haruspec
    </div>
  );
};

/** The two real conformance lines, each typed on with its role colour as a left rule. */
const Conformances: React.FC<{ at: number; tintAt: number[]; dim: number }> = ({ at, tintAt, dim }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.45);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: EXT.x,
        top: EXT.top,
        width: EXT.w,
        boxSizing: "border-box",
        padding: `${EXT.pad}px 20px`,
        borderRadius: 16,
        border: `3px solid ${C.text}`,
        background: `linear-gradient(180deg, ${C.text}1C, ${C.text}08)`,
        opacity: o * mix(1, 0.4, dim),
        transform: `translateY(${(1 - Math.min(1, o)) * 12}px)`,
        display: "flex",
        flexDirection: "column",
        gap: EXT.gap,
      }}
    >
      {CONFORMANCES.map(({ text, color }, i) => {
        const t0 = at + Math.round(i * 0.45 * fps);
        const n = frame < t0 ? 0 : Math.round(lin(frame, t0, 0.6, fps) * text.length);
        const tint = frame < tintAt[i] ? 0 : prog(frame, tintAt[i], 0.4, fps);
        return (
          <div
            key={i}
            style={{
              borderLeft: `5px solid ${color}`,
              paddingLeft: 16,
              borderRadius: 4,
              fontFamily: FONT.mono,
              fontSize: CARD.size,
              lineHeight: `${LH}px`,
              height: LH,
              whiteSpace: "pre",
              color: C.text,
              opacity: frame < t0 ? 0 : 1,
              background: `${color}${Math.round(tint * 0x26).toString(16).padStart(2, "0")}`,
            }}
          >
            {text.slice(0, n)}
          </div>
        );
      })}
    </div>
  );
};

/** A small rounded tag, vertically centred on `y`, its left edge at `x`. */
const Tag: React.FC<{ x: number; y: number; at: number; out?: number; color: string; children: React.ReactNode }> = ({ x, y, at, out, color, children }) => {
  const o = useAppear(at, out, 0.45);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(${(1 - Math.min(1, o)) * -10}px, -50%)`,
        fontFamily: FONT.serif,
        fontSize: 26,
        color,
        border: `2.5px solid ${color}`,
        borderRadius: 999,
        padding: "2px 18px",
        background: C.surface,
        whiteSpace: "nowrap",
        opacity: o,
      }}
    >
      {children}
    </div>
  );
};

/** A generated type: a mono name that slides out from the spine, and a serif caption that writes on
 *  when the narration names it. `y` is its centre. */
const Chip: React.FC<{ y: number; name: string; caption: string; at: number; captionAt: number; opacity: number; glow: number }> = ({
  y,
  name,
  caption,
  at,
  captionAt,
  opacity,
  glow,
}) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, 0.5, fps);
  const cap = frame < captionAt ? 0 : prog(frame, captionAt, 0.6, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: mix(SPINE_X + 10, CHIP.left, p),
        top: y - CHIP.h / 2,
        width: CHIP.w,
        height: CHIP.h,
        boxSizing: "border-box",
        padding: "0 26px",
        borderRadius: 14,
        border: `3px solid ${C.text}`,
        background: C.surface,
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        opacity: p * opacity,
        boxShadow: glow > 0 ? `0 0 ${34 * glow}px ${C.text}88` : "none",
      }}
    >
      <div style={{ fontFamily: FONT.mono, fontSize: 34, lineHeight: "44px", color: C.text }}>{name}</div>
      <div
        style={{
          fontFamily: FONT.serif,
          fontStyle: "italic",
          fontSize: 28,
          lineHeight: "34px",
          color: C.dim,
          whiteSpace: "nowrap",
          clipPath: `inset(0 ${(1 - cap) * 100}% 0 0)`,
        }}
      >
        {caption}
      </div>
    </div>
  );
};

export const Stamp: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const start = cue("It starts");
  const target = cue("test target");
  const paste = cue("Paste");
  const initializer = cue("initializer included");
  const stampIt = cue("stamp it");
  const declare = cue("Then declare");
  const conform = cue("both conform");
  const oneLine = cue("one line each");
  const each = cue("each");
  const never = cue("never imports Haruspec");
  const isMacro = cue("The stamp is a macro");
  const macro = cue("macro");
  const oneProtocol = cue("that one protocol");
  const three = cue("three things");
  const forwarder = cue("forwarder");
  const records = cue("records every call");
  const returns = cue("its return value");
  const catalog = cue("catalog of operations");
  const standIn = cue("stand-in");
  const seams = cue("seams video");
  const subject = cue("the cart is the subject");

  // The body writes on line by line from "Paste"; line 0 waits for the stamp.
  const lines = PROTOCOL.map((ln, i) => {
    if (i === 0) return " ";
    const t0 = paste + s((i - 1) * 0.09);
    const n = frame < t0 ? 0 : Math.round(lin(frame, t0, 0.3, fps) * ln.length);
    return n === 0 ? " " : ln.slice(0, n);
  });

  const cardDim = track(frame, fps, [[0, 0], [three, 0.4]]);
  const cardGlow = track(frame, fps, [[0, 0], [oneProtocol, 0.7], [three + s(0.5), 0]]);
  const stampGlow = track(frame, fps, [[0, 0], [stampIt, 1], [declare, 0.3], [macro, 1], [forwarder, 0.45]]);
  const extDim = track(frame, fps, [[0, 0], [isMacro, 1]]);

  // Focus moves chip to chip as each is named; at "the cart is the subject" the forwarder comes back.
  const tracedOpacity = track(frame, fps, [[0, 1], [catalog, 0.5], [subject, 1]]);
  const tracedGlow = track(frame, fps, [[0, 0], [forwarder, 1], [catalog, 0], [subject, 1]]);
  const derivedOpacity = track(frame, fps, [[0, 1], [forwarder, 0.5], [catalog, 1], [standIn, 0.5], [subject, 0.45]]);
  const derivedGlow = track(frame, fps, [[0, 0], [catalog, 1], [standIn, 0]]);
  const doubleOpacity = track(frame, fps, [[0, 1], [forwarder, 0.5], [standIn, 1], [seams, 0.35]]);
  const doubleGlow = track(frame, fps, [[0, 0], [standIn, 0.8], [seams, 0]]);

  const cardFade = mix(1, 0.3, cardDim);
  const targetIn = frame < target ? 0 : prog(frame, target, 0.5, fps);
  const simplifiedIn = frame < paste ? 0 : prog(frame, paste, 0.5, fps);
  const drop = frame < records ? 0 : prog(frame, records, 0.45, fps);

  return (
    <>
      {/* Tints sit under the card's translucent wash. */}
      <Band from={2} to={7} color={ROLE.seam} at={initializer} out={stampIt} />
      <Band from={0} to={0} color={C.text} at={stampIt} alpha="16" />

      <CodeCard
        x={CARD.x}
        y={CARD_Y}
        w={CARD.w}
        file="SubjectBoundaries.swift"
        lines={lines}
        color={C.text}
        size={CARD.size}
        at={start}
        dim={cardDim}
        glow={cardGlow}
      />
      {/* Header note, right-aligned in the card's header. */}
      <div
        style={{
          position: "absolute",
          left: CARD.x - CARD.w / 2 + 3,
          top: CARD.top + 3,
          width: CARD.w - 6,
          height: 52,
          boxSizing: "border-box",
          padding: "0 24px",
          display: "flex",
          alignItems: "center",
          justifyContent: "flex-end",
          fontFamily: FONT.serif,
          fontStyle: "italic",
          fontSize: 26,
          color: C.dim,
          opacity: cardFade,
          whiteSpace: "pre",
        }}
      >
        <span style={{ opacity: targetIn }}>test target</span>
        <span style={{ opacity: simplifiedIn }}> · simplified</span>
      </div>
      <StampLine at={stampIt} glow={stampGlow} />
      <Tag x={264} y={TRUNK_Y} at={macro} color={C.dim}>
        <span style={{ fontStyle: "italic" }}>macro</span>
      </Tag>

      <Conformances at={conform} tintAt={[oneLine, each]} dim={extDim} />
      <Tag x={EXT.x + EXT.w + 28} y={extMid(1)} at={never} out={isMacro + s(0.4)} color={ROLE.candidate}>
        <span style={{ fontFamily: FONT.mono }}>SwiftCart.swift</span>
        <span style={{ color: C.text }}> imports Foundation only</span>
      </Tag>

      {/* From the stamp: a trunk along line 0, a spine, and a branch into each generated type. */}
      <Svg>
        <Arrow from={[392, TRUNK_Y]} to={[CHIP.left - 6, TRUNK_Y]} at={three} dur={0.55} color={C.dim} width={2.5} head />
        <Line from={[SPINE_X, TRUNK_Y]} to={[SPINE_X, CHIP_Y.double]} at={three + s(0.35)} dur={0.4} color={C.dim} width={2.5} />
        <Arrow from={[SPINE_X, CHIP_Y.derived]} to={[CHIP.left - 6, CHIP_Y.derived]} at={three + s(0.55)} dur={0.25} color={C.dim} width={2.5} head />
        <Arrow from={[SPINE_X, CHIP_Y.double]} to={[CHIP.left - 6, CHIP_Y.double]} at={three + s(0.7)} dur={0.25} color={C.dim} width={2.5} head />
      </Svg>

      <Chip y={CHIP_Y.traced} name="TracedCart" caption="forwarder" at={three + s(0.3)} captionAt={forwarder} opacity={tracedOpacity} glow={tracedGlow} />
      <Chip y={CHIP_Y.derived} name="DerivedCart" caption="catalog of operations" at={three + s(0.6)} captionAt={catalog} opacity={derivedOpacity} glow={derivedGlow} />
      <Chip y={CHIP_Y.double} name="DoubleCart" caption="stand-in" at={three + s(0.75)} captionAt={standIn} opacity={doubleOpacity} glow={doubleGlow} />
      <Tag x={CHIP.left + CHIP.w + 28} y={CHIP_Y.double} at={seams} color={C.dim}>
        <span style={{ fontFamily: FONT.mono }}>→</span> seams video
      </Tag>

      {/* The forwarder's record: illustrative rows that drop in under it. */}
      <div style={{ position: "absolute", left: 0, top: 0, transform: `translateY(${(1 - drop) * -18}px)` }}>
        <TraceStrip
          x={CHIP.left + 30}
          y={CHIP_Y.traced + CHIP.h / 2 + 22}
          rows={TRACE}
          color={C.dim}
          title="illustrative values"
          at={records}
          stagger={(returns - records) / fps}
          w={680}
          opacity={tracedOpacity}
        />
      </div>
    </>
  );
};
