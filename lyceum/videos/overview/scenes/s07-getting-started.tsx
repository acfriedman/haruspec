import React from "react";
import { useScene, Line, Svg, C, FONT, MONO_ADVANCE, mix, prog, track, visibility } from "#kit";
import { ROLE, useAppear } from "./shared";

// Three steps as an accordion down the left: each step is a header strip (numeral + title); the active
// step opens below its header, earlier ones fold back to strips. The continuous shape plays out in the
// right column: a terminal, a branch diagram, and the specs a change touches (illustrative names).
// Code is the project's own (the stamp line is simplified); the package lines are shown exploded.

const SIZE = 26;
const LH = 40;
const ADV = SIZE * MONO_ADVANCE;

// The left column (x 80 to 1170) and its accordion metrics.
const LEFT = 80;
const COL_W = 1090;
const PAD_X = 28;
const PAD_Y = 20;
const TOP = 130;
const HC = 56; // a folded header strip
const HE = 88; // the open step's header
const GAP_HB = 14; // header to body
const GAP_S = 22; // between steps

// Body heights (each body's content is laid out from its top).
const B1 = 5 * LH + 14 + 2 * PAD_Y; // the package panel
const B2_FULL = 446; // stamp, derived operations, spec
const B2_CONT = 302; // @Continuous chip over the spec
const B3 = 196; // the test panel and the port chip

// Body tops once their step is open (constant within a phase).
const BODY1 = TOP + HE + GAP_HB;
const BODY2 = TOP + HC + GAP_S + HE + GAP_HB;
const BODY3 = TOP + 2 * (HC + GAP_S) + HE + GAP_HB;
const BODY2_CONT = TOP + HC + GAP_S + HC + GAP_HB;

// The right column (x 1210 to 1840).
const RX = 1210;
const RW = 630;
const RCX = RX + RW / 2;

type Seg = { t: string; c?: string };
type CodeLine = string | Seg[];
const segs = (l: CodeLine): Seg[] => (typeof l === "string" ? [{ t: l }] : l);
const lineText = (l: CodeLine) => segs(l).map((x) => x.t).join("");

type Mark = { line: number; from: number; to: number; at: number; color: string };

/** Code lines at `x`/`y` (top-left of the first line), each writing on left to right from its own
 *  frame in `ats`. `gapBefore` adds pixels above a line; `marks` box a column span from a frame on. */
const CodeLines: React.FC<{ x: number; y: number; lines: CodeLine[]; ats: number[]; gapBefore?: Record<number, number>; marks?: Mark[]; out?: number }> = ({
  x,
  y,
  lines,
  ats,
  gapBefore = {},
  marks = [],
  out,
}) => {
  const { frame, fps } = useScene();
  const fade = visibility(frame, fps, undefined, out);
  if (fade <= 0) return null;
  let cursor = y;
  const tops = lines.map((_, i) => {
    cursor += gapBefore[i] ?? 0;
    const t = cursor;
    cursor += LH;
    return t;
  });
  return (
    <div style={{ opacity: fade }}>
      {marks.map((m, i) => {
        const p = frame < m.at ? 0 : prog(frame, m.at, 0.4, fps);
        if (p <= 0) return null;
        return (
          <div
            key={`m${i}`}
            style={{
              position: "absolute",
              left: x + m.from * ADV - 6,
              top: tops[m.line] + 3,
              width: (m.to - m.from) * ADV + 12,
              height: LH - 6,
              boxSizing: "border-box",
              borderRadius: 8,
              border: `2px solid ${m.color}`,
              background: `${m.color}26`,
              opacity: p,
              transform: `scale(${mix(1.08, 1, p)})`,
            }}
          />
        );
      })}
      {lines.map((l, i) => {
        const at = ats[i];
        const len = lineText(l).length;
        const p = frame < at ? 0 : prog(frame, at, Math.min(0.8, Math.max(0.3, len / 60)), fps);
        if (p <= 0) return null;
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: x,
              top: tops[i],
              height: LH,
              lineHeight: `${LH}px`,
              fontFamily: FONT.mono,
              fontSize: SIZE,
              whiteSpace: "pre",
              color: C.text,
              clipPath: `inset(0 ${(1 - p) * 100}% 0 0)`,
            }}
          >
            {segs(l).map((sg, j) => (
              <span key={j} style={{ color: sg.c ?? C.text }}>
                {sg.t}
              </span>
            ))}
          </div>
        );
      })}
    </div>
  );
};

/** A code panel: a surface with a faint rule. `x`/`y` are its top-left. */
const Panel: React.FC<{ x: number; y: number; w: number; h: number; at: number; out?: number; glow?: number; glowColor?: string }> = ({ x, y, w, h, at, out, glow = 0, glowColor = C.text }) => {
  const o = useAppear(at, out, 0.45);
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
        borderRadius: 14,
        border: `2px solid ${glow > 0 ? glowColor : C.faint}`,
        background: C.surface,
        opacity: o,
        transform: `scale(${mix(0.97, 1, o)})`,
        boxShadow: glow > 0 ? `0 0 ${34 * glow}px ${glowColor}` : "none",
      }}
    />
  );
};

/** A short label, vertically centred on `y`, anchored at `x` by `align`. */
const Label: React.FC<{ x: number; y: number; at: number; out?: number; size?: number; color?: string; mono?: boolean; align?: "left" | "center" | "right"; children: React.ReactNode }> = ({
  x,
  y,
  at,
  out,
  size = 28,
  color = C.dim,
  mono = false,
  align = "left",
  children,
}) => {
  const o = useAppear(at, out, 0.5);
  if (o <= 0) return null;
  const tx = align === "left" ? "0" : align === "center" ? "-50%" : "-100%";
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(${tx}, -50%)`,
        fontFamily: mono ? FONT.mono : FONT.serif,
        fontStyle: mono ? "normal" : "italic",
        fontSize: size,
        color,
        whiteSpace: "nowrap",
        opacity: o,
      }}
    >
      {children}
    </div>
  );
};

/** A step header: a large numeral and a title while the step is open (`k` = 1), a one-line strip
 *  ("1 · Add the package") once folded (`k` = 0). The numeral shows from `numAt`, the title writes
 *  on at `titleAt`. `y` is its top. */
const StepHeader: React.FC<{ n: number; title: string; y: number; k: number; numAt: number; titleAt: number }> = ({ n, title, y, k, numAt, titleAt }) => {
  const { frame, fps } = useScene();
  const no = frame < numAt ? 0 : prog(frame, numAt, 0.45, fps);
  if (no <= 0) return null;
  const tp = frame < titleAt ? 0 : prog(frame, titleAt, 0.6, fps);
  const h = mix(HC, HE, k);
  const tone = mix(0.62, 1, k);
  return (
    <div style={{ position: "absolute", left: LEFT, top: y, width: COL_W, height: h, opacity: no, transform: `translateY(${(1 - no) * 10}px)` }}>
      <div style={{ position: "absolute", inset: 0, boxSizing: "border-box", borderRadius: 12, background: C.surface, border: `2px solid ${C.faint}`, opacity: 1 - k }} />
      <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", paddingLeft: mix(22, 0, k) }}>
        <div style={{ width: mix(26, 64, k), textAlign: "center", fontFamily: FONT.serif, fontSize: mix(32, 80, k), lineHeight: 1, color: C.text, opacity: tone }}>{n}</div>
        <div style={{ width: mix(36, 22, k), textAlign: "center", fontFamily: FONT.serif, fontSize: 30, color: C.text, opacity: tone * tp * (1 - k) }}>·</div>
        <div style={{ fontFamily: FONT.serif, fontSize: mix(30, 46, k), color: C.text, opacity: tone, whiteSpace: "nowrap", clipPath: `inset(0 ${(1 - tp) * 100}% 0 0)` }}>{title}</div>
      </div>
    </div>
  );
};

/** A tick that draws on. */
const Tick: React.FC<{ p: number; size: number; color: string }> = ({ p, size, color }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" style={{ display: "block" }}>
    <path d="M4 12.5 L10 18 L20 6" fill="none" stroke={color} strokeWidth={3} strokeLinecap="round" strokeLinejoin="round" pathLength={1} strokeDasharray="1" strokeDashoffset={1 - p} opacity={p > 0 ? 1 : 0} />
  </svg>
);

/** A spec chip in the replay row: neutral from `at`, then from `litAt` either lit in the candidate's
 *  colour (`touched`) or greyed out. */
const SpecChip: React.FC<{ name: string; at: number; litAt: number; touched: boolean }> = ({ name, at, litAt, touched }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.4);
  const lp = frame < litAt ? 0 : prog(frame, litAt, 0.5, fps);
  const chip: React.CSSProperties = {
    fontFamily: FONT.mono,
    fontSize: SIZE,
    lineHeight: "40px",
    padding: "0 14px",
    borderRadius: 999,
    whiteSpace: "nowrap",
    boxSizing: "border-box",
  };
  return (
    <div style={{ position: "relative", opacity: o * (touched ? 1 : mix(1, 0.32, lp)), transform: `translateY(${(1 - o) * 10}px)` }}>
      <div style={{ ...chip, color: C.text, border: `2px solid ${C.dim}` }}>{name}</div>
      {touched && lp > 0 && (
        <div style={{ ...chip, position: "absolute", inset: 0, color: ROLE.candidate, border: `2px solid ${ROLE.candidate}`, background: `${C.bg}`, opacity: lp }}>
          <div style={{ position: "absolute", inset: 0, borderRadius: 999, background: `${ROLE.candidate}22` }} />
          <span style={{ position: "relative" }}>{name}</span>
        </div>
      )}
    </div>
  );
};

const PACKAGE: CodeLine[] = [
  ".package(",
  '    url: "https://github.com/acfriedman/haruspec.git",',
  '    branch: "main"',
  ")",
  '.product(name: "Haruspec", package: "haruspec")',
];

const STAMP: CodeLine[] = [[{ t: "@Haruspec", c: C.purple }, { t: " protocol Cart: AnyObject { … }" }]];

const SPEC: CodeLine[] = [
  "Spec<Cart> {",
  '    Amend("applyPromo")',
  '        .varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))',
  '    Amend("checkout").last()',
  "}",
];
const ONE_OF = '.oneOf("SAVE10", "save10", "NOPE")';
const ONE_OF_FROM = lineText(SPEC[2]).indexOf(ONE_OF);
const LAST_FROM = lineText(SPEC[3]).indexOf(".last()");

const TEST: CodeLine[] = [
  [{ t: "let subject = spec.baselined(on: " }, { t: "CartManager", c: ROLE.baseline }, { t: ".self)" }],
  [{ t: "try await subject.check(" }, { t: "SwiftCart", c: ROLE.candidate }, { t: ".self)" }],
];
const CART_MANAGER_FROM = lineText(TEST[0]).indexOf("CartManager");
const SWIFT_CART_FROM = lineText(TEST[1]).indexOf("SwiftCart");

// The derived operations: blank chips that fan out of the stamp.
const FAN_X = [190, 360, 530, 700];
const STAMP_W = 680;

export const GettingStarted: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const three = cue("three steps");
  const addPkg = cue("Add the package");
  const spm = cue("Swift Package Manager");
  const product = cue("one product");
  const writeSpec = cue("Write a spec");
  const stamp = cue("Stamp the protocol");
  const derive = cue("derive from its signatures");
  const saysOnly = cue("says only what a signature");
  const promo = cue("which promo codes matter");
  const last = cue("checkout runs last");
  const thenCheck = cue("Then check");
  const inTest = cue("In a test");
  const bind = cue("bind the legacy class");
  const baseline = cue("the baseline");
  const port = cue("check the port");
  const noAttr = cue("no Haruspec attribute");
  const conform = cue("Conforming to the protocol");
  const contShape = cue("For the continuous shape");
  const shape = cue("continuous shape");
  const optIn = cue("opt the repository in");
  const once = cue("once");
  const markSpec = cue("mark the spec continuous");
  const runCheck = cue("run haruspec check");
  const anyBranch = cue("any branch");
  const records = cue("It records behavior");
  const leftMain = cue("where your branch left main");
  const leftMainWord = cue("left main");
  const replays = cue("replays only the specs");
  const touches = cue("your change touches");
  const machine = cue("on your machine");

  // The accordion: `k` sizes each header (open or strip), `e` opens each body.
  const T = 0.7;
  const k1 = track(frame, fps, [[0, 0], [addPkg, 1], [writeSpec + s(0.3), 0]], T);
  const k2 = track(frame, fps, [[0, 0], [writeSpec + s(0.3), 1], [thenCheck + s(0.3), 0]], T);
  const k3 = track(frame, fps, [[0, 0], [thenCheck + s(0.3), 1], [contShape + s(0.3), 0]], T);
  const e2 = track(frame, fps, [[0, 0], [writeSpec + s(0.3), 1], [thenCheck + s(0.3), 0], [markSpec, 1]], T);
  const b2 = frame >= markSpec ? B2_CONT : B2_FULL;
  const hh = (k: number) => mix(HC, HE, k);
  const y1 = TOP;
  const y2 = y1 + hh(k1) + k1 * (GAP_HB + B1) + GAP_S;
  const y3 = y2 + hh(k2) + e2 * (GAP_HB + b2) + GAP_S;

  // Step 3's port chip.
  const chipTop = BODY3 + 120 + 24;
  const chipO = useAppear(noAttr, contShape, 0.45);
  const tickP = frame < noAttr + s(0.45) ? 0 : prog(frame, noAttr + s(0.45), 0.5, fps);
  const underline = frame < conform ? 0 : prog(frame, conform, 0.6, fps);

  // The @Continuous chip slides out from behind the terminal, level with its slot above the spec.
  const slideAt = markSpec + s(0.3);
  const landAt = slideAt + s(1.0);
  const contO = useAppear(markSpec, undefined, 0.4);
  const contTop = BODY2_CONT;
  const contLeft = track(frame, fps, [[0, 1190], [slideAt, LEFT]], 1.0);
  const landGlow = frame < landAt ? 0 : prog(frame, landAt, 0.3, fps) * (1 - prog(frame, landAt + s(0.5), 0.8, fps));

  // The left column steps back once the narration moves to the branch.
  const leftDim = mix(1, 0.55, frame < records ? 0 : prog(frame, records, 0.8, fps));

  // Terminal.
  const termTop = TOP;
  const termH = 40 + 16 + 4 * LH + 20;
  const termO = useAppear(shape, undefined, 0.5);
  const CPS = 30;
  const typed = (text: string, at: number) => (frame < at ? "" : text.slice(0, Math.floor(((frame - at) / fps) * CPS)));
  const prompt2 = once + s(0.5);
  const termRows: { text: string; prompt: boolean; show: number; typeAt?: number }[] = [
    { text: ".haruspec/bin/haruspec init", prompt: true, show: shape, typeAt: optIn },
    { text: "  # once", prompt: false, show: once },
    { text: ".haruspec/bin/haruspec check", prompt: true, show: prompt2, typeAt: runCheck },
    { text: "  # any branch", prompt: false, show: anyBranch },
  ];
  const cursorRow = frame < once ? 0 : frame >= prompt2 && frame < anyBranch ? 2 : -1;
  const blinkOn = Math.floor(frame / (fps * 0.5)) % 2 === 0;

  // Branch diagram.
  const MAIN_Y = 520;
  const BRANCH_Y = 446;
  const MB_X = 1420;
  const TIP_X = 1790;
  const branchP = frame < leftMain + s(0.3) ? 0 : prog(frame, leftMain + s(0.3), 0.7, fps);
  const mbP = frame < leftMainWord ? 0 : prog(frame, leftMainWord, 0.4, fps);
  const tipP = frame < leftMain + s(0.9) ? 0 : prog(frame, leftMain + s(0.9), 0.3, fps);

  return (
    <>
      <div style={{ opacity: leftDim }}>
        {/* Headers. */}
        <StepHeader n={1} title="Add the package" y={y1} k={k1} numAt={three} titleAt={addPkg} />
        <StepHeader n={2} title="Write a spec" y={y2} k={k2} numAt={three + s(0.15)} titleAt={writeSpec} />
        <StepHeader n={3} title="Check" y={y3} k={k3} numAt={three + s(0.3)} titleAt={thenCheck} />

        {/* Step 1: the package. */}
        <Panel x={LEFT} y={BODY1} w={COL_W} h={B1} at={addPkg + s(0.25)} out={writeSpec} />
        <CodeLines
          x={LEFT + PAD_X}
          y={BODY1 + PAD_Y}
          lines={PACKAGE}
          ats={[addPkg + s(0.45), addPkg + s(0.6), addPkg + s(0.8), addPkg + s(0.95), product]}
          gapBefore={{ 4: 14 }}
          out={writeSpec}
        />
        <Label x={LEFT + COL_W - 24} y={BODY1 + PAD_Y + LH / 2} at={spm} out={writeSpec} size={26} mono align="right">
          Package.swift
        </Label>

        {/* Step 2: stamp, derived operations, spec. */}
        <Panel x={LEFT} y={BODY2} w={STAMP_W} h={LH + 2 * PAD_Y} at={stamp} out={thenCheck} />
        <CodeLines x={LEFT + PAD_X} y={BODY2 + PAD_Y} lines={STAMP} ats={[stamp + s(0.2)]} out={thenCheck} />
        <Label x={LEFT + STAMP_W + 30} y={BODY2 + PAD_Y + LH / 2} at={stamp + s(0.8)} out={thenCheck}>
          simplified
        </Label>
        <Svg>
          {FAN_X.map((cx, i) => (
            <Line key={i} from={[LEFT + STAMP_W / 2, BODY2 + 80]} to={[cx, BODY2 + 136]} at={derive + s(0.1 * i)} dur={0.5} color={C.dim} width={2} opacity={0.55} out={thenCheck} />
          ))}
        </Svg>
        {FAN_X.map((cx, i) => {
          const t0 = derive + s(0.1 * i);
          const p = frame < t0 ? 0 : prog(frame, t0, 0.6, fps);
          const o = p * visibility(frame, fps, undefined, thenCheck);
          if (o <= 0) return null;
          const x = mix(LEFT + STAMP_W / 2, cx, p);
          const y = mix(BODY2 + 90, BODY2 + 158, p);
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                left: x - 70,
                top: y - 22,
                width: 140,
                height: 44,
                boxSizing: "border-box",
                borderRadius: 999,
                border: `2px solid ${C.dim}`,
                background: `${C.text}08`,
                opacity: 0.75 * o,
                transform: `scale(${mix(0.5, 1, p)})`,
              }}
            />
          );
        })}
        <Label x={790} y={BODY2 + 158} at={derive + s(0.6)} out={thenCheck}>
          one operation per requirement
        </Label>
        <Panel x={LEFT} y={BODY2 + 206} w={COL_W} h={5 * LH + 2 * PAD_Y} at={saysOnly} out={thenCheck} />
        <CodeLines
          x={LEFT + PAD_X}
          y={BODY2 + 206 + PAD_Y}
          lines={SPEC}
          ats={[saysOnly + s(0.15), saysOnly + s(0.35), saysOnly + s(0.55), saysOnly + s(0.95), saysOnly + s(1.15)]}
          marks={[
            { line: 2, from: ONE_OF_FROM, to: ONE_OF_FROM + ONE_OF.length, at: promo, color: ROLE.plan },
            { line: 3, from: LAST_FROM, to: LAST_FROM + ".last()".length, at: last, color: ROLE.plan },
          ]}
          out={thenCheck}
        />

        {/* Step 3: bind the baseline, check the port. */}
        <Panel x={LEFT} y={BODY3} w={COL_W} h={2 * LH + 2 * PAD_Y} at={inTest} out={contShape} />
        <Label x={LEFT + COL_W - 24} y={BODY3 + PAD_Y + LH / 2} at={inTest + s(0.2)} out={contShape} size={26} align="right">
          in a test
        </Label>
        <CodeLines
          x={LEFT + PAD_X}
          y={BODY3 + PAD_Y}
          lines={TEST}
          ats={[bind, port]}
          marks={[
            { line: 0, from: CART_MANAGER_FROM, to: CART_MANAGER_FROM + "CartManager".length, at: baseline, color: ROLE.baseline },
            { line: 1, from: SWIFT_CART_FROM, to: SWIFT_CART_FROM + "SwiftCart".length, at: port + s(0.6), color: ROLE.candidate },
          ]}
          out={contShape}
        />
        {chipO > 0 && (
          <div style={{ position: "absolute", left: LEFT, top: chipTop, height: 52, display: "flex", alignItems: "center", gap: 18, opacity: chipO, transform: `translateY(${(1 - Math.min(1, chipO)) * 10}px)` }}>
            <div
              style={{
                fontFamily: FONT.mono,
                fontSize: SIZE,
                lineHeight: "46px",
                padding: "0 18px",
                borderRadius: 999,
                border: `2.5px solid ${ROLE.candidate}`,
                background: `${ROLE.candidate}14`,
                color: C.text,
                whiteSpace: "pre",
              }}
            >
              {"class "}
              <span style={{ color: ROLE.candidate }}>SwiftCart</span>
              {": "}
              <span style={{ position: "relative" }}>
                Cart
                <span
                  style={{
                    position: "absolute",
                    left: 0,
                    right: 0,
                    bottom: 2,
                    height: 3,
                    borderRadius: 2,
                    background: ROLE.equivalent,
                    transform: `scaleX(${underline})`,
                    transformOrigin: "left",
                  }}
                />
              </span>
            </div>
            <Tick p={tickP} size={38} color={ROLE.equivalent} />
            <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 28, color: C.dim, opacity: tickP }}>no attribute</div>
          </div>
        )}

        {/* Step 2 again: the spec, now marked continuous. */}
        <Panel x={LEFT} y={BODY2_CONT + 62} w={COL_W} h={5 * LH + 2 * PAD_Y} at={markSpec + s(0.3)} glow={landGlow} glowColor={C.purple} />
        <CodeLines x={LEFT + PAD_X} y={BODY2_CONT + 62 + PAD_Y} lines={SPEC} ats={SPEC.map(() => markSpec + s(0.4))} />
        {contO > 0 && (
          <div
            style={{
              position: "absolute",
              left: contLeft,
              top: contTop,
              height: 48,
              boxSizing: "border-box",
              fontFamily: FONT.mono,
              fontSize: SIZE,
              lineHeight: "43px",
              padding: "0 18px",
              borderRadius: 999,
              border: `2.5px solid ${C.purple}`,
              background: C.surface,
              color: C.text,
              whiteSpace: "pre",
              opacity: contO,
              boxShadow: landGlow > 0 ? `0 0 ${26 * landGlow}px ${C.purple}` : "none",
            }}
          >
            <span style={{ color: C.purple }}>@Continuous</span>
            {"(baseline: "}
            <span style={{ color: ROLE.baseline }}>CartManager</span>
            {".self)"}
          </div>
        )}
      </div>

      {/* The continuous shape: a terminal. */}
      {termO > 0 && (
        <div
          style={{
            position: "absolute",
            left: RX,
            top: termTop,
            width: RW,
            height: termH,
            boxSizing: "border-box",
            borderRadius: 14,
            border: `2px solid ${C.faint}`,
            background: C.surface,
            opacity: termO,
            transform: `scale(${mix(0.97, 1, termO)})`,
            overflow: "hidden",
          }}
        >
          <div style={{ height: 40, display: "flex", alignItems: "center", gap: 10, padding: "0 20px", borderBottom: `2px solid ${C.faint}` }}>
            {[0, 1, 2].map((i) => (
              <div key={i} style={{ width: 12, height: 12, borderRadius: 6, background: C.faint }} />
            ))}
          </div>
          <div style={{ padding: `16px ${PAD_X}px` }}>
            {termRows.map((r, i) => {
              const p = frame < r.show ? 0 : prog(frame, r.show, 0.3, fps);
              const body = r.prompt ? typed(r.text, r.typeAt ?? r.show) : r.text;
              const typing = r.prompt && body.length > 0 && body.length < r.text.length;
              return (
                <div key={i} style={{ height: LH, lineHeight: `${LH}px`, fontFamily: FONT.mono, fontSize: SIZE, whiteSpace: "pre", opacity: p, display: "flex", alignItems: "center" }}>
                  {r.prompt ? (
                    <>
                      <span style={{ color: C.dim }}>{"$ "}</span>
                      <span style={{ color: C.text }}>{body}</span>
                    </>
                  ) : (
                    <span style={{ color: C.dim }}>{r.text}</span>
                  )}
                  {cursorRow === i && (typing || blinkOn) && <span style={{ display: "inline-block", width: ADV, height: 30, marginLeft: 2, background: C.text, opacity: 0.8 }} />}
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Where the branch left main. */}
      <Svg>
        <Line from={[RX + 20, MAIN_Y]} to={[RX + RW - 20, MAIN_Y]} at={leftMain} dur={0.6} color={ROLE.baseline} width={5} />
        <path
          d={`M ${MB_X} ${MAIN_Y} C ${MB_X + 70} ${MAIN_Y} ${MB_X + 80} ${BRANCH_Y} ${MB_X + 160} ${BRANCH_Y} L ${TIP_X} ${BRANCH_Y}`}
          fill="none"
          stroke={ROLE.candidate}
          strokeWidth={5}
          strokeLinecap="round"
          pathLength={1}
          strokeDasharray="1"
          strokeDashoffset={1 - branchP}
          opacity={branchP > 0 ? 1 : 0}
        />
        <circle cx={MB_X} cy={MAIN_Y} r={13 * mbP} fill={ROLE.baseline} />
        <circle cx={TIP_X} cy={BRANCH_Y} r={10 * tipP} fill={ROLE.candidate} />
      </Svg>
      <Label x={RX + 20} y={MAIN_Y - 32} at={leftMain + s(0.4)} color={ROLE.baseline}>
        main
      </Label>
      <Label x={MB_X} y={MAIN_Y + 42} at={leftMainWord} color={C.text} align="center">
        merge base
      </Label>
      <Label x={TIP_X} y={BRANCH_Y - 38} at={leftMain + s(0.9)} color={ROLE.candidate} align="right">
        your branch
      </Label>

      {/* Only the specs the change touches replay. */}
      <Label x={RCX} y={640} at={replays} size={26} align="center">
        illustrative specs
      </Label>
      <div style={{ position: "absolute", left: RCX, top: 670, transform: "translateX(-50%)", display: "flex", gap: 40 }}>
        {[
          { names: ["cart", "checkout"], touched: true, label: "replayed" },
          { names: ["catalog", "profile"], touched: false, label: "untouched" },
        ].map((g, gi) => (
          <div key={gi} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10 }}>
            <div style={{ display: "flex", gap: 18 }}>
              {g.names.map((n, i) => (
                <SpecChip key={n} name={n} at={replays + s(0.12 * (gi * 2 + i))} litAt={touches} touched={g.touched} />
              ))}
            </div>
            <div
              style={{
                fontFamily: FONT.serif,
                fontStyle: "italic",
                fontSize: 26,
                color: g.touched ? ROLE.candidate : C.dim,
                opacity: frame < touches + s(0.3) ? 0 : prog(frame, touches + s(0.3), 0.5, fps),
              }}
            >
              {g.label}
            </div>
          </div>
        ))}
      </div>
      <Label x={RCX} y={850} at={machine} size={32} color={C.text} align="center">
        on your machine
      </Label>
    </>
  );
};
