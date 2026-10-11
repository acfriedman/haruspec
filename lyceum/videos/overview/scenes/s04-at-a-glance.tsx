import React from "react";
import { useScene, Code, Fade, C, FONT, LINE_HEIGHT, MONO_ADVANCE, codePoint, mix, prog, track, visibility } from "#kit";
import { ROLE, useAppear } from "./shared";

// The README's At a glance, verbatim, plus the `Ordering(max: 10)` line its output needs; the
// `print(verdict.report())` line is left off. The explored grid on the right is illustrative: the real
// run explored 6 orderings × 64 seam variants, and only the 6 is shown.

const CODE_LINES = [
  'let cart = Spec<PromoCart>("promo-cart")',
  "    .operations {",
  '        Op("addCoffee") { cart, seams in',
  '            cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))',
  "        }",
  '        Op("promo") { $0.applyPromo() }',
  '        Op("checkout") { _ = $0.checkout() }.last()',
  "    }",
  "    .vary {",
  '        Seam("coffeeQty", .int(1 ... 20))',
  "        Ordering(max: 10)",
  "    }",
  "",
  "let verdict = await cart.baselined(on: makeLegacyCart).verify(candidate: makeSwiftPort)",
];
const CODE = CODE_LINES.join("\n");

// The longest line is 88 characters: 24 px is the largest size that fits beside the explored panel.
const SIZE = 24;
const ADV = MONO_ADVANCE * SIZE;

const CARD = { x: 80, y: 182, w: 1312, header: 56, padX: 24, padTop: 22, padBottom: 26 };
const CODE_X = CARD.x + CARD.padX;
const CODE_Y = CARD.y + CARD.header + CARD.padTop;
const CARD_H = CARD.header + CARD.padTop + CODE_LINES.length * SIZE * LINE_HEIGHT + CARD.padBottom;
const CARD_BOTTOM = CARD.y + CARD_H;
const CARD_CX = CARD.x + CARD.w / 2;

// The explored panel: rows are orderings, columns are coffeeQty 1 … 20.
const PANEL = { x: 1440, r: 1840 };
const GRID = { x: 1486, y: 336, colPitch: 17.4, cellW: 13, rowPitch: 40, cellH: 28, cols: 20, rows: 6 };
const GRID_R = GRID.x + (GRID.cols - 1) * GRID.colPitch + GRID.cellW;
const GRID_B = GRID.y + (GRID.rows - 1) * GRID.rowPitch + GRID.cellH;
/** The row whose ordering repeats operations, and the coffeeQty = 10 column. */
const TWICE_ROW = 3;
const TEN_COL = 9;

/** Columns `[from, to)` of `needle` on a code line; throws if the code changed under it. */
function span(line: number, needle: string) {
  const from = CODE_LINES[line].indexOf(needle);
  if (from < 0) throw new Error(`at-a-glance: "${needle}" is not on line ${line}`);
  return { line, from, to: from + needle.length };
}

/** The frame x of the middle of a span. */
function spanMid(sp: { line: number; from: number; to: number }) {
  return codePoint(CODE_X, CODE_Y, SIZE, sp.line, sp.from).x + ((sp.to - sp.from) * ADV) / 2;
}

/** Inline content that writes on left to right from `at`. `x`/`y` are its left edge, centre or right
 *  edge (per `align`) and its vertical centre; `rotate` turns it about that point. */
const WriteOn: React.FC<{
  x: number;
  y: number;
  at: number;
  dur?: number;
  out?: number;
  align?: "left" | "center" | "right";
  rotate?: number;
  children: React.ReactNode;
}> = ({ x, y, at, dur = 0.6, out, align = "left", rotate = 0, children }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, dur, fps);
  const o = Math.min(1, p * 4) * visibility(frame, fps, undefined, out);
  if (o <= 0) return null;
  const tx = align === "left" ? "0" : align === "center" ? "-50%" : "-100%";
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(${tx}, -50%) rotate(${rotate}deg)`,
        transformOrigin: align === "center" ? "50% 50%" : "0 50%",
        whiteSpace: "nowrap",
        padding: "6px 0",
        clipPath: `inset(0 ${(1 - p) * 100}% 0 0)`,
        opacity: o,
      }}
    >
      {children}
    </div>
  );
};

const mono = (color: string, size = 26): React.CSSProperties => ({ fontFamily: FONT.mono, fontSize: size, color });
const serif = (color: string, size = 26): React.CSSProperties => ({ fontFamily: FONT.serif, fontStyle: "italic", fontSize: size, color });

/** The spec's card: a surface panel with a title strip. The code itself is the kit's `Code`, drawn over it. */
const SpecCard: React.FC<{ at: number }> = ({ at }) => {
  const o = useAppear(at);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: CARD.x,
        top: CARD.y,
        width: CARD.w,
        height: CARD_H,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `2px solid ${C.faint}`,
        background: C.surface,
        opacity: o,
        transform: `scale(${mix(0.97, 1, o)})`,
      }}
    >
      <div style={{ height: CARD.header, borderBottom: `2px solid ${C.faint}` }} />
    </div>
  );
};

/** A scan line that sweeps the card top to bottom from `at`, over `dur` seconds. */
const Scan: React.FC<{ at: number; dur: number; color: string }> = ({ at, dur, color }) => {
  const { frame, fps } = useScene();
  if (frame < at) return null;
  const p = prog(frame, at, dur, fps);
  const o = Math.min(1, (frame - at) / (0.15 * fps)) * (1 - prog(frame, at + Math.round(dur * fps), 0.3, fps));
  if (o <= 0) return null;
  const y = mix(0, CARD_H, p);
  return (
    <div style={{ position: "absolute", left: CARD.x, top: CARD.y, width: CARD.w, height: CARD_H, borderRadius: 16, overflow: "hidden", opacity: o }}>
      <div style={{ position: "absolute", left: 0, right: 0, top: y - 90, height: 90, background: `linear-gradient(180deg, ${color}00, ${color}26)` }} />
      <div style={{ position: "absolute", left: 0, right: 0, top: y - 2, height: 4, background: color, boxShadow: `0 0 18px ${color}` }} />
    </div>
  );
};

/** One grid cell: a faint outline from `showAt`, filling with the seam tint from `fillAt`. */
const Cell: React.FC<{ x: number; y: number; showAt: number; fillAt: number }> = ({ x, y, showAt, fillAt }) => {
  const { frame, fps } = useScene();
  if (frame < showAt) return null;
  const shown = prog(frame, showAt, 0.3, fps);
  const fill = frame < fillAt ? 0 : prog(frame, fillAt, 0.3, fps);
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width: GRID.cellW,
        height: GRID.cellH,
        boxSizing: "border-box",
        borderRadius: 3,
        border: `1.5px solid ${fill > 0.5 ? ROLE.seam : C.faint}`,
        background: `${ROLE.seam}${Math.round(fill * 0xc0)
          .toString(16)
          .padStart(2, "0")}`,
        opacity: shown,
        transform: `translateY(${(1 - shown) * -8}px)`,
      }}
    />
  );
};

/** A rounded outline drawn around a region, fading in at `at` (and out at `out`). */
const Ring: React.FC<{ x: number; y: number; w: number; h: number; at: number; out?: number; color: string }> = ({ x, y, w, h, at, out, color }) => {
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width: w,
        height: h,
        boxSizing: "border-box",
        borderRadius: 7,
        border: `2.5px solid ${color}`,
        opacity: o,
        transform: `scale(${mix(1.06, 1, o)})`,
      }}
    />
  );
};

export const AtAGlance: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const here = cue("Here's");
  const whole = cue("whole authored surface");
  const small = cue("small promo cart");
  const three = cue("Three operations");
  const addCoffee = cue("Add some coffee");
  const apply = cue("Apply the promo");
  const checkOut = cue("Check out");
  const always = cue("always runs last");
  const aSeam = cue("a seam");
  const oneTo = cue("from one to twenty");
  const every = cue("every order");
  const allows = cue("the spec allows");
  const twice = cue("some of them twice");
  const oneLine = cue("Then one line");
  const legacy = cue("legacy cart");
  const verifyIt = cue("Verify the Swift port");
  const notice = cue("Notice");
  const noExpected = cue("No expected total");
  const anywhere = cue("anywhere");
  const nobody = cue("Nobody worked out");
  const tenCoffees = cue("ten coffees");

  const baselineSpan = span(13, "baselined(on: makeLegacyCart)");
  const candidateSpan = span(13, "verify(candidate: makeSwiftPort)");

  // Highlights move with the words; the baseline and candidate stay lit to the end.
  const highlights = [
    { ...span(0, 'Spec<PromoCart>("promo-cart")'), at: small, out: three, color: C.text },
    { ...span(1, ".operations"), at: three, out: addCoffee, color: C.text },
    { ...span(2, CODE_LINES[2].trim()), at: addCoffee, out: apply, color: C.text },
    { ...span(3, CODE_LINES[3].trim()), at: addCoffee, out: apply, color: C.text },
    { ...span(4, "}"), at: addCoffee, out: apply, color: C.text },
    { ...span(5, CODE_LINES[5].trim()), at: apply, out: checkOut, color: C.text },
    { ...span(6, 'Op("checkout") { _ = $0.checkout() }'), at: checkOut, out: always, color: C.text },
    { ...span(6, ".last()"), at: always, out: aSeam, color: C.text },
    { ...span(3, '"coffeeQty"'), at: aSeam, out: every, color: ROLE.seam },
    { ...span(9, '"coffeeQty"'), at: aSeam, out: every, color: ROLE.seam },
    { ...span(9, ".int(1 ... 20)"), at: oneTo, out: every, color: ROLE.seam },
    { ...span(10, "Ordering(max: 10)"), at: every, out: oneLine, color: C.text },
    { ...span(13, CODE_LINES[13]), at: oneLine, out: legacy, color: C.text },
    { ...baselineSpan, at: legacy, color: ROLE.baseline },
    { ...candidateSpan, at: verifyIt, color: ROLE.candidate },
  ];

  // The explored panel steps back while the last line is read, and returns for the closing thought.
  const panel = track(frame, fps, [[0, 1], [oneLine, 0.5], [nobody, 1]], 0.6);
  // On "twice", the other orderings dim so the repeated one stands out.
  const others = track(frame, fps, [[0, 1], [twice, 0.4], [oneLine, 1]], 0.5);

  const cells: React.ReactNode[] = [];
  for (let r = 0; r < GRID.rows; r++) {
    const showAt = r === 0 ? aSeam + s(0.5) : every + s(0.1 * r);
    for (let c = 0; c < GRID.cols; c++) {
      const fillAt = r === 0 ? oneTo + s(0.035 * c) : every + s(0.15 + 0.1 * r + 0.02 * c);
      cells.push(
        <Cell key={`${r}-${c}`} x={GRID.x + c * GRID.colPitch} y={GRID.y + r * GRID.rowPitch} showAt={r === 0 ? showAt + s(0.012 * c) : showAt} fillAt={fillAt} />,
      );
    }
  }
  const rowOpacity = (r: number) => (r === TWICE_ROW ? 1 : others);

  return (
    <>
      {/* The spec: everything anyone authors for the promo cart. */}
      <SpecCard at={here} />
      <WriteOn x={CARD.x + 26} y={CARD.y + CARD.header / 2} at={whole} dur={0.8}>
        <span style={mono(C.text)}>promo-cart</span>
        <span style={serif(C.dim, 28)}>{"  ·  the whole authored surface"}</span>
      </WriteOn>
      <Code code={CODE} x={CODE_X} y={CODE_Y} size={SIZE} at={here + s(0.25)} cps={Infinity} highlights={highlights} />

      {/* The one line: which code is trusted, which is checked. */}
      <Fade x={spanMid(baselineSpan)} y={CARD_BOTTOM + 36} anchor="center" at={legacy + s(0.3)} out={notice} rise={8}>
        <div style={serif(ROLE.baseline, 28)}>baseline</div>
      </Fade>
      <Fade x={spanMid(candidateSpan)} y={CARD_BOTTOM + 36} anchor="center" at={verifyIt + s(0.3)} out={notice} rise={8}>
        <div style={serif(ROLE.candidate, 28)}>candidate</div>
      </Fade>

      {/* Nothing in it says what the answer should be. */}
      <Scan at={noExpected} dur={1.15} color={ROLE.equivalent} />
      <Fade x={CARD_CX} y={CARD_BOTTOM + 72} anchor="center" at={anywhere} rise={14}>
        <div
          style={{
            ...mono(ROLE.equivalent, 28),
            border: `2.5px solid ${ROLE.equivalent}`,
            borderRadius: 999,
            padding: "6px 24px",
            background: `${ROLE.equivalent}14`,
            whiteSpace: "nowrap",
          }}
        >
          expected values: 0
        </div>
      </Fade>

      {/* Explored: what the spec makes the oracle sweep. */}
      <div style={{ position: "absolute", inset: 0, opacity: panel }}>
        <WriteOn x={PANEL.x} y={220} at={aSeam} dur={0.5}>
          <span style={serif(C.text, 34)}>explored</span>
        </WriteOn>
        <WriteOn x={PANEL.r} y={224} at={aSeam + s(0.3)} dur={0.4} align="right">
          <span style={serif(C.dim)}>illustrative</span>
        </WriteOn>
        <div
          style={{
            position: "absolute",
            left: PANEL.x,
            top: 252,
            height: 2,
            width: (PANEL.r - PANEL.x) * (frame < aSeam ? 0 : prog(frame, aSeam, 0.6, fps)),
            background: C.faint,
          }}
        />

        <WriteOn x={GRID.x} y={300} at={aSeam + s(0.2)} dur={0.5}>
          <span style={mono(ROLE.seam)}>coffeeQty</span>
        </WriteOn>
        <WriteOn x={GRID.x + 10 * 26 * MONO_ADVANCE} y={300} at={oneTo} dur={0.6}>
          <span style={mono(C.dim)}>1 … 20</span>
        </WriteOn>

        {cells.map((cell, i) => (
          <div key={i} style={{ opacity: rowOpacity(Math.floor(i / GRID.cols)) }}>
            {cell}
          </div>
        ))}

        <WriteOn x={GRID.x - 30} y={(GRID.y + GRID_B) / 2} at={allows} dur={0.6} align="center" rotate={-90}>
          <span style={serif(C.text, 28)}>6 orderings</span>
        </WriteOn>

        {/* One ordering that repeats operations. */}
        <Ring
          x={GRID.x - 6}
          y={GRID.y + TWICE_ROW * GRID.rowPitch - 6}
          w={GRID_R - GRID.x + 12}
          h={GRID.cellH + 12}
          at={twice}
          out={oneLine}
          color={C.text}
        />
        <WriteOn x={(GRID.x + GRID_R) / 2} y={GRID_B + 62} at={twice + s(0.15)} dur={0.5} out={oneLine} align="center">
          <span style={mono(C.text)}>addCoffee</span>
          <span style={mono(C.dim)}> → </span>
          <span style={mono(C.text)}>addCoffee</span>
          <span style={mono(C.dim)}> →</span>
        </WriteOn>
        <WriteOn x={(GRID.x + GRID_R) / 2} y={GRID_B + 104} at={twice + s(0.55)} dur={0.5} out={oneLine} align="center">
          <span style={mono(C.text)}>promo</span>
          <span style={mono(C.dim)}> → </span>
          <span style={mono(C.text)}>promo</span>
          <span style={mono(C.dim)}> → </span>
          <span style={mono(C.text)}>checkout</span>
        </WriteOn>

        {/* Ten coffees and a promo: one column of the sweep, never worked out by hand. */}
        <Ring
          x={GRID.x + TEN_COL * GRID.colPitch - 5}
          y={GRID.y - 6}
          w={GRID.cellW + 10}
          h={GRID_B - GRID.y + 12}
          at={tenCoffees}
          color={C.text}
        />
      </div>
    </>
  );
};
