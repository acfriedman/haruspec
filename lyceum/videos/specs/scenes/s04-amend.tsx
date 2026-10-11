import React from "react";
import { useScene, Arrow, Svg, Text, C, FONT, MONO_ADVANCE, prog, lin, mix, smooth, track, visibility } from "#kit";
import { CodeCard, ROLE, useAppear } from "./shared";

// Sources. The trap is DerivedOps.swift's binding trap with the names filled in. The spec is
// CartMigrationSpec.swift (example-xcode-migration/LegacyAppTests) with its comments removed. The
// replacing operation is the "derived.replace" spec in Tests/SpecTests/DerivedOpsTests.swift. The table
// is a compact recall of scene 3's.

const SIZE = 26;
const CH = SIZE * MONO_ADVANCE;
const LH = SIZE * 1.55;
/** Argument values, and the amendment lines that declare them. */
const VALUE = ROLE.seam;
const PENDING = ROLE.cannotVerify;

type P = [number, number];

// ── The table (scene 3's, compact) ─────────────────────────────────────────────────────────────────

const COL = { req: 180, op: 600, domain: 860, badge: 1690 } as const;
const TABLE_L = 160;
const TABLE_R = 1760;
const HEAD_Y = 150;
const ROW_Y = [215, 265, 315, 365];

type RowSpec = { req: string; op: string; pending?: string; domain?: React.ReactNode };

const mono = (text: string, color: string = C.text) => <span style={{ fontFamily: FONT.mono, color }}>{text}</span>;
const prose = (text: string, color: string = C.text, italic = false) => (
  <span style={{ fontFamily: FONT.serif, color, fontStyle: italic ? "italic" : "normal" }}>{text}</span>
);

const ROWS: RowSpec[] = [
  {
    req: "add(_:quantity:)",
    op: "add",
    domain: (
      <>
        {mono("quantity")}
        {prose(": magnitude ladder · ")}
        {mono("product")}
        {prose(": its own generator")}
      </>
    ),
  },
  { req: "removeSku(_:)", op: "removeSku", pending: "sku" },
  { req: "applyPromo(_:)", op: "applyPromo", pending: "code" },
  { req: "checkout()", op: "checkout", domain: prose("no arguments", C.dim, true) },
];

const Cell: React.FC<{ x: number; y: number; children: React.ReactNode }> = ({ x, y, children }) => (
  <div style={{ position: "absolute", left: x, top: y, transform: "translateY(-50%)", whiteSpace: "nowrap", fontSize: SIZE, lineHeight: `${LH}px` }}>{children}</div>
);

/** A repetition badge, centred at `x`/`y`; `sy` squashes it vertically for a flip. */
const Badge: React.FC<{ x: number; y: number; text: string; color: string; sy?: number }> = ({ x, y, text, color, sy = 1 }) =>
  sy <= 0 ? null : (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) scaleY(${sy})`,
        fontFamily: FONT.mono,
        fontSize: SIZE,
        lineHeight: "36px",
        color,
        border: `2px solid ${color}`,
        borderRadius: 999,
        padding: "0 14px",
        background: C.surface,
        whiteSpace: "nowrap",
      }}
    >
      {text}
    </div>
  );

/** One table row. A pending argument gets an amber cell; `pendingP` writes its label in, `glow` rings it. */
const Row: React.FC<{ y: number; row: RowSpec; pendingP?: number; glow?: number; wash?: number; badge: React.ReactNode }> = ({ y, row, pendingP = 0, glow = 0, wash = 0, badge }) => (
  <>
    {wash > 0 && (
      <div style={{ position: "absolute", left: TABLE_L - 12, top: y - 23, width: TABLE_R - TABLE_L + 24, height: 46, borderRadius: 8, background: `${C.text}14`, opacity: wash }} />
    )}
    <Cell x={COL.req} y={y}>{mono(row.req)}</Cell>
    <Cell x={COL.op} y={y}>{mono(row.op)}</Cell>
    {row.pending ? (
      <>
        <div
          style={{
            position: "absolute",
            left: COL.domain - 16,
            top: y - 22,
            width: 1600 - COL.domain,
            height: 44,
            boxSizing: "border-box",
            borderRadius: 8,
            border: `2px solid ${PENDING}88`,
            background: `${PENDING}1A`,
            boxShadow: glow > 0 ? `0 0 ${30 * glow}px ${PENDING}` : "none",
          }}
        />
        <Cell x={COL.domain} y={y}>
          {mono(row.pending, PENDING)}
          <span
            style={{
              display: "inline-block",
              marginLeft: 22,
              fontFamily: FONT.serif,
              fontStyle: "italic",
              color: PENDING,
              border: `2px solid ${PENDING}`,
              borderRadius: 999,
              padding: "0 14px",
              lineHeight: "32px",
              opacity: pendingP,
              transform: `translateX(${(1 - pendingP) * -10}px)`,
            }}
          >
            pending
          </span>
        </Cell>
      </>
    ) : (
      <Cell x={COL.domain} y={y}>{row.domain}</Cell>
    )}
    {badge}
  </>
);

const pulse = (frame: number, fps: number, at: number, seconds: number) =>
  frame < at ? 0 : Math.sin(Math.PI * Math.min(1, (frame - at) / (seconds * fps)));

/** Scene 3's table, back with its string cells pending. */
const PendingTable: React.FC<{ out: number; pendingAt: number; pulses: number[]; magicAt: number; washIn: number; washOut: number }> = ({ out, pendingAt, pulses, magicAt, washIn, washOut }) => {
  const { frame, fps } = useScene();
  const o = useAppear(0, out, 0.4);
  if (o <= 0) return null;
  const pendingP = prog(frame, pendingAt, 0.5, fps);
  const glow = Math.max(...pulses.map((t) => pulse(frame, fps, t, 1.4)));
  const magic = pulse(frame, fps, magicAt, 1.4);
  const wash = frame < washIn ? 0 : prog(frame, washIn, 0.4, fps) * (1 - prog(frame, washOut, 0.4, fps));
  const head = (x: number, text: string) => (
    <Cell x={x} y={HEAD_Y}>
      {prose(text, C.dim, true)}
    </Cell>
  );
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, opacity: o }}>
      {head(COL.req, "requirement")}
      {head(COL.op, "operation")}
      {head(COL.domain, "argument → domain")}
      <div style={{ position: "absolute", left: TABLE_L, top: HEAD_Y + 28, width: TABLE_R - TABLE_L, height: 2, background: C.faint }} />
      {ROWS.map((row, i) => (
        <Row
          key={i}
          y={ROW_Y[i]}
          row={row}
          pendingP={pendingP}
          glow={i === 2 ? Math.max(glow, magic) : glow}
          wash={i === 2 ? wash : 0}
          badge={<Badge x={COL.badge} y={ROW_Y[i]} text="× 0…3" color={C.dim} />}
        />
      ))}
    </div>
  );
};

// ── The applyPromo branch ──────────────────────────────────────────────────────────────────────────

const EXITS = [
  { label: "match", x: 560, w: 200 },
  { label: "case-insensitive match", x: 960, w: 360 },
  { label: "no match", x: 1360, w: 220 },
] as const;
const DY = 180;
const ROOT_W = 260;
const ROOT_H = 68;
const EXIT_H = 60;
const edgeFrom = (ry: number, ex: number): P => [960 + (ex - 960) * 0.15, ry + ROOT_H / 2 + 4];
const edgeTo = (ry: number, ex: number): P => [ex, ry + DY - EXIT_H / 2 - 4];

/** A node of the branch: a rounded box that lights `VALUE` on its first hit and bumps on each. */
const Station: React.FC<{ x: number; y: number; w: number; h: number; label: string; isMono?: boolean; at: number; out: number; hits?: number[] }> = ({
  x,
  y,
  w,
  h,
  label,
  isMono = false,
  at,
  out,
  hits = [],
}) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.5);
  if (o <= 0) return null;
  const first = hits.length ? Math.min(...hits) : undefined;
  const lit = first === undefined ? 0 : prog(frame, first, 0.35, fps);
  const latest = hits.filter((t) => frame >= t).at(-1);
  const bump = latest === undefined ? 0 : pulse(frame, fps, latest, 0.4);
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
        border: `2.5px solid ${C.dim}`,
        background: C.surface,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: isMono ? FONT.mono : FONT.serif,
        fontSize: isMono ? 28 : SIZE,
        color: C.text,
        whiteSpace: "nowrap",
        opacity: o,
        transform: `scale(${mix(0.92, 1, o) * (1 + 0.06 * bump)})`,
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: -2.5,
          borderRadius: 14,
          border: `2.5px solid ${VALUE}`,
          background: `${VALUE}22`,
          opacity: lit,
          boxShadow: bump > 0 ? `0 0 ${26 * bump}px ${VALUE}` : "none",
        }}
      />
      <span style={{ position: "relative" }}>{label}</span>
    </div>
  );
};

/** The three-exit branch `applyPromo` takes, root centred at (960, `ry`). `lit[i]` lights exit i's edge;
 *  `hits[i]` are the frames a value reaches exit i. */
const Branch: React.FC<{ ry: number; at: number; out: number; lit: (number | undefined)[]; hits: number[][] }> = ({ ry, at, out, lit, hits }) => {
  const { fps } = useScene();
  const s = (sec: number) => Math.round(sec * fps);
  return (
    <>
      <Svg>
        {EXITS.map((e, i) => (
          <Arrow key={i} from={edgeFrom(ry, e.x)} to={edgeTo(ry, e.x)} at={at + s(0.25 + i * 0.12)} out={out} dur={0.5} color={C.dim} width={2.5} />
        ))}
        {EXITS.map((e, i) =>
          lit[i] === undefined ? null : <Arrow key={`lit${i}`} from={edgeFrom(ry, e.x)} to={edgeTo(ry, e.x)} at={lit[i]!} out={out} dur={0.3} color={VALUE} width={3.5} />,
        )}
      </Svg>
      <Station x={960} y={ry} w={ROOT_W} h={ROOT_H} label="applyPromo" isMono at={at} out={out} />
      {EXITS.map((e, i) => (
        <Station key={i} x={e.x} y={ry + DY} w={e.w} h={EXIT_H} label={e.label} at={at + s(0.45 + i * 0.12)} out={out} hits={hits[i]} />
      ))}
    </>
  );
};

// ── Moving values ──────────────────────────────────────────────────────────────────────────────────

/** A keyframe: [frame, x, y, opacity]. Equal frames make a jump. */
type Key = [number, number, number, number];

function sample(frame: number, keys: Key[]) {
  if (frame < keys[0][0]) return null;
  for (let i = 1; i < keys.length; i++) {
    const [f1, x1, y1, o1] = keys[i];
    if (frame <= f1) {
      const [f0, x0, y0, o0] = keys[i - 1];
      const t = f1 === f0 ? 1 : smooth((frame - f0) / (f1 - f0));
      return { x: mix(x0, x1, t), y: mix(y0, y1, t), o: mix(o0, o1, t) };
    }
  }
  const [, x, y, o] = keys[keys.length - 1];
  return { x, y, o };
}

const chip = (color: string): React.CSSProperties => ({
  fontFamily: FONT.mono,
  fontSize: SIZE,
  lineHeight: "36px",
  color,
  border: `2.5px solid ${color}`,
  borderRadius: 999,
  padding: "0 14px",
  background: C.surface,
  whiteSpace: "nowrap",
});

/** A value chip that follows its keyframes. */
const Mover: React.FC<{ text: string; keys: Key[]; out?: number }> = ({ text, keys, out }) => {
  const { frame, fps } = useScene();
  const p = sample(frame, keys);
  if (!p) return null;
  const o = p.o * (out === undefined ? 1 : visibility(frame, fps, undefined, out));
  if (o <= 0.01) return null;
  return <div style={{ position: "absolute", left: p.x, top: p.y, transform: "translate(-50%, -50%)", ...chip(VALUE), opacity: o }}>{text}</div>;
};

// ── The hollow verdict and the trap ────────────────────────────────────────────────────────────────

const LEFT_HALF = "polygon(0 0, 53% 0, 47% 28%, 55% 52%, 46% 76%, 52% 100%, 0 100%)";
const RIGHT_HALF = "polygon(53% 0, 100% 0, 100% 100%, 52% 100%, 46% 76%, 55% 52%, 47% 28%)";

/** A dashed EQUIVALENT pill that cracks in two at `crackAt`. */
const HollowPill: React.FC<{ x: number; y: number; at: number; crackAt: number; out: number }> = ({ x, y, at, crackAt, out }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.45);
  if (o <= 0) return null;
  const k = prog(frame, crackAt, 0.5, fps);
  const color = ROLE.equivalent;
  const pill = (clip: string | undefined, dx: number, dy: number, rot: number) => (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translate(-50%, -50%) translate(${dx}px, ${dy}px) rotate(${rot}deg) scale(${mix(0.85, 1, Math.min(1, o))})`,
        clipPath: clip,
        fontFamily: FONT.mono,
        fontWeight: 600,
        fontSize: 32,
        color,
        border: `3px dashed ${color}`,
        background: `${color}14`,
        borderRadius: 999,
        padding: "6px 24px",
        whiteSpace: "nowrap",
        opacity: o * mix(1, 0.55, k),
      }}
    >
      ✅ EQUIVALENT
    </div>
  );
  if (k <= 0) return pill(undefined, 0, 0, 0);
  return (
    <>
      {pill(LEFT_HALF, -12 * k, 6 * k, -4 * k)}
      {pill(RIGHT_HALF, 12 * k, -4 * k, 4 * k)}
    </>
  );
};

const TRAP = [
  "derived op 'applyPromo' has no domain for",
  "'code: String' — a String has no honest default.",
  "Declare its values:",
  'Amend("applyPromo").varying("code", over: .oneOf(…))',
];

/** The binding trap's message, typed on from `at`; its last line, the line to write, lights at `markAt`. */
const TrapCard: React.FC<{ x: number; y: number; at: number; out: number; markAt: number }> = ({ x, y, at, out, markAt }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, out, 0.4);
  if (o <= 0) return null;
  const total = TRAP.reduce((n, l) => n + l.length, 0);
  let left = Math.floor(lin(frame, at, 1.4, fps) * total);
  const mark = prog(frame, markAt, 0.4, fps);
  const color = ROLE.diverged;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width: 900,
        boxSizing: "border-box",
        transform: `translate(-50%, -50%) scale(${mix(0.94, 1, o)})`,
        borderRadius: 16,
        border: `3px solid ${color}`,
        background: `linear-gradient(180deg, ${color}1C, ${color}08)`,
        opacity: o,
        boxShadow: `0 0 ${30 * pulse(frame, fps, at, 0.9)}px ${color}`,
      }}
    >
      <div style={{ height: 52, display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 28px", borderBottom: `2px solid ${color}55`, fontFamily: FONT.mono, fontSize: SIZE }}>
        <span style={{ color }}>trap</span>
        <span style={{ color: C.dim }}>DerivedOps.swift</span>
      </div>
      <div style={{ padding: "18px 20px" }}>
        {TRAP.map((ln, i) => {
          const shown = Math.max(0, Math.min(ln.length, left));
          left -= ln.length;
          const isLast = i === TRAP.length - 1;
          return (
            <div
              key={i}
              style={{
                fontFamily: FONT.mono,
                fontSize: SIZE,
                lineHeight: `${LH}px`,
                whiteSpace: "pre",
                color: C.text,
                padding: "0 8px",
                borderRadius: 6,
                background: isLast && mark > 0 ? `${VALUE}${Math.round(mark * 0x33).toString(16).padStart(2, "0")}` : undefined,
              }}
            >
              {ln.slice(0, shown)}
              <span style={{ opacity: 0 }}>{ln.slice(shown)}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
};

// ── The spec card ──────────────────────────────────────────────────────────────────────────────────

const SPEC = [
  "Spec<Cart> {",
  '    Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))',
  '    Amend("removeSku").varying("sku", over: .oneOf(Catalog.skus))',
  '    Amend("checkout").last()',
  "}",
  ".comparing(Comparison(concurrency: .perDomain))",
  ".provides((() -> UUID).self) { _ in Minted.identifiers() }",
  ".provides((() -> Date).self) { _ in { Minted.instant } }",
];
const SEAMS = [5, 6, 7];

const SPEC_Y = 345;
const SPEC_W = 1500;
/** CodeCard's geometry: its height for `n` lines, and where its code starts inside it. */
const cardH = (n: number) => 52 + n * LH + 36;
const CODE_LEFT = 3 + 24;
const BODY_TOP = 3 + 54 + 18;
const SPEC_TOP = SPEC_Y - cardH(SPEC.length) / 2;

/** The centre of `token` on spec line `line`, in frame coordinates (card at its home position). */
const tokenAt = (line: number, token: string): P => {
  const col = SPEC[line].indexOf(token);
  return [960 - SPEC_W / 2 + CODE_LEFT + (col + token.length / 2) * CH, SPEC_TOP + BODY_TOP + (line + 0.5) * LH];
};

/** The spec's code, drawn over an empty CodeCard of the same size so lines can dim and light on their
 *  own: `washes[i]` tints line i, `boxes` ring tokens, `lineOpacity[i]` dims it. */
const SpecLines: React.FC<{
  x: number;
  at: number;
  out: number;
  lineOpacity: number[];
  washes: number[];
  boxes: { line: number; token: string; o: number }[];
}> = ({ x, at, out, lineOpacity, washes, boxes }) => {
  const o = useAppear(at, out);
  if (o <= 0) return null;
  const h = cardH(SPEC.length);
  const seamsRight = CODE_LEFT + Math.max(...SEAMS.map((i) => SPEC[i].length)) * CH + 34;
  return (
    <div style={{ position: "absolute", left: x - SPEC_W / 2, top: SPEC_Y - h / 2, width: SPEC_W, height: h, opacity: o, transform: `scale(${mix(0.94, 1, o)})` }}>
      {washes.map((lv, i) =>
        lv <= 0 ? null : (
          <div
            key={`w${i}`}
            style={{ position: "absolute", left: CODE_LEFT - 12, top: BODY_TOP + i * LH, width: SPEC_W - 2 * CODE_LEFT + 24, height: LH, borderRadius: 6, background: `${VALUE}30`, opacity: lv }}
          />
        ),
      )}
      {boxes.map((b, i) => {
        if (b.o <= 0) return null;
        const col = SPEC[b.line].indexOf(b.token);
        return (
          <div
            key={`b${i}`}
            style={{
              position: "absolute",
              left: CODE_LEFT + col * CH - 3,
              top: BODY_TOP + b.line * LH + 3,
              width: b.token.length * CH + 6,
              height: LH - 6,
              boxSizing: "border-box",
              border: `2.5px solid ${VALUE}`,
              borderRadius: 6,
              opacity: b.o * lineOpacity[b.line],
            }}
          />
        );
      })}
      {SPEC.map((ln, i) => (
        <div
          key={i}
          style={{ position: "absolute", left: CODE_LEFT, top: BODY_TOP + i * LH, fontFamily: FONT.mono, fontSize: SIZE, lineHeight: `${LH}px`, whiteSpace: "pre", color: C.text, opacity: lineOpacity[i] }}
        >
          {ln}
        </div>
      ))}
      {/* The seams lines, bracketed and pointed elsewhere. */}
      <div
        style={{
          position: "absolute",
          left: seamsRight,
          top: BODY_TOP + SEAMS[0] * LH + 4,
          width: 14,
          height: SEAMS.length * LH - 8,
          boxSizing: "border-box",
          border: `2px solid ${C.dim}`,
          borderLeft: "none",
          borderRadius: "0 6px 6px 0",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: seamsRight + 30,
          top: BODY_TOP + (SEAMS[0] + 1.5) * LH,
          transform: "translateY(-50%)",
          fontFamily: FONT.serif,
          fontStyle: "italic",
          fontSize: SIZE,
          color: C.dim,
          whiteSpace: "nowrap",
        }}
      >
        seams video
      </div>
    </div>
  );
};

// ── Orderings and the full Op ──────────────────────────────────────────────────────────────────────

type StripItem = { code: string; litAt: number; tag?: string; tagAt?: number; hard?: boolean };

/** The ordering vocabulary: modifier pills that write on from `at`, light on their word, and take a tag. */
const Strip: React.FC<{ y: number; at: number; out: number; items: StripItem[] }> = ({ y, at, out, items }) => {
  const { frame, fps } = useScene();
  const fade = visibility(frame, fps, undefined, out);
  if (frame < at || fade <= 0) return null;
  return (
    <div style={{ position: "absolute", left: 960, top: y, transform: "translate(-50%, -26px)", display: "flex", gap: 64, opacity: fade }}>
      {items.map((it, i) => {
        const p = prog(frame, at + Math.round(i * 0.18 * fps), 0.45, fps);
        const lit = prog(frame, it.litAt, 0.35, fps);
        const bump = pulse(frame, fps, it.litAt, 0.5);
        const tag = it.tagAt === undefined ? 0 : prog(frame, it.tagAt, 0.4, fps);
        return (
          <div key={i} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 16, opacity: p, transform: `translateY(${(1 - p) * 12}px)` }}>
            <div
              style={{
                position: "relative",
                fontFamily: FONT.mono,
                fontSize: 28,
                lineHeight: "44px",
                color: C.text,
                border: `2px solid ${C.text}55`,
                borderRadius: 999,
                padding: "0 22px",
                whiteSpace: "nowrap",
                transform: `scale(${1 + 0.06 * bump})`,
              }}
            >
              <div
                style={{
                  position: "absolute",
                  inset: -2,
                  borderRadius: 999,
                  border: `2.5px solid ${VALUE}`,
                  background: `${VALUE}22`,
                  opacity: lit,
                  boxShadow: bump > 0 ? `0 0 ${24 * bump}px ${VALUE}` : "none",
                }}
              />
              <span style={{ position: "relative" }}>{it.code}</span>
            </div>
            <div style={{ height: 44, display: "flex", alignItems: "center" }}>
              {it.tag && (
                <span
                  style={{
                    fontFamily: FONT.serif,
                    fontStyle: "italic",
                    fontWeight: it.hard ? 600 : 400,
                    fontSize: SIZE,
                    lineHeight: "36px",
                    color: C.text,
                    border: it.hard ? `3px solid ${C.text}` : `2px dashed ${C.text}`,
                    borderRadius: 8,
                    padding: "0 14px",
                    opacity: tag,
                    transform: `translateY(${(1 - tag) * -10}px)`,
                    display: "inline-block",
                  }}
                >
                  {it.tag}
                </span>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
};

/** The operation the stamp derived: a dashed chip with a caption, struck from `strikeAt`. */
const TwinChip: React.FC<{ x: number; y: number; at: number; strikeAt: number }> = ({ x, y, at, strikeAt }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at, undefined, 0.5);
  if (o <= 0) return null;
  const strike = prog(frame, strikeAt, 0.4, fps);
  return (
    <div style={{ position: "absolute", left: x, top: y, transform: "translate(-50%, -26px)", display: "flex", flexDirection: "column", alignItems: "center", gap: 10, opacity: o }}>
      <div
        style={{
          position: "relative",
          fontFamily: FONT.mono,
          fontSize: 30,
          lineHeight: "46px",
          color: C.text,
          border: `2.5px dashed ${C.dim}`,
          borderRadius: 999,
          padding: "0 26px",
          opacity: mix(1, 0.45, strike),
          transform: `translateY(${(1 - Math.min(1, o)) * 10}px)`,
        }}
      >
        add
        <div style={{ position: "absolute", left: 12, top: "50%", height: 4, width: `calc(${strike} * (100% - 24px))`, background: ROLE.diverged }} />
      </div>
      <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: SIZE, color: C.dim }}>derived</div>
    </div>
  );
};

const REPLACE = [
  'Spec<MeteredCart>("derived.replace") {',
  "    Op(",
  '        "add",',
  '        varying: .oneOf("COFFEE").named("sku"),',
  '        .int(1 ... 5).named("quantity")',
  "    ) { cart, sku, quantity in",
  "        cart.add(sku: sku, quantity: quantity)",
  "    }",
  '    Amend("total").last()',
  "}",
];
const REPLACE_Y = 560;
const SKUS = ["BEANS", "COFFEE", "FILTER", "MUG"];

// ── The scene ──────────────────────────────────────────────────────────────────────────────────────

export const Amend: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);
  /** 0 → 1 from `inAt`, back to 0 from `outAt`. */
  const span = (inAt: number, outAt?: number, d = 0.4) =>
    frame < inAt ? 0 : prog(frame, inAt, d, fps) * (outAt === undefined || frame < outAt ? 1 : 1 - prog(frame, outAt, d, fps));

  // 1 · strings stay pending, and binding traps
  const strings = cue("Strings get nothing");
  const nothing = cue("nothing");
  const magic = cue("magic words");
  const promo = cue("promo code");
  const random = cue("random text");
  const green = cue("green");
  const hollow = cue("hollow");
  const so = cue("So a string");
  const stays = cue("stays pending");
  const traps = cue("binding the spec traps");
  const naming = cue("naming the line");
  // 2 · the three lines
  const three = cue("That's what the three lines");
  const threeLines = cue("three lines");
  const amendPromo = cue("Amend apply promo");
  const codeWord = cue("the code over");
  const save = cue("save ten");
  const lower = cue("the same in lowercase");
  const nope = cue("nope");
  const aMatch = cue("a match");
  const ciMatch = cue("a case-insensitive match");
  const noMatch = cue("no match");
  const remove = cue("the remove operation");
  const product = cue("product code");
  const catalogue = cue("catalogue");
  const checkout = cue("And amend checkout");
  const last = cue("it runs last");
  // 3 · the ordering vocabulary
  const rest = cue("The rest shapes");
  const once = cue("run once");
  const repeat = cue("repeat");
  const follow = cue("follow another operation");
  const breaks = cue("breaks on purpose");
  const requireOne = cue("require one");
  const never = cue("never does");
  // 4 · a full Op replaces its derived twin
  const call = cue("the call itself");
  const differ = cue("must differ");
  const replaces = cue("replaces its derived twin");
  const derived = cue("derived twin");
  const twin = cue("twin");

  // Phase 1: random strings all fall through "no match".
  const P1 = 490;
  const noX = EXITS[2].x;
  const randoms = ["x7Qa", "ploo", "ZZ9"].map((text, i) => {
    const t = random + s(i * 0.5);
    const [fx, fy] = edgeFrom(P1, noX);
    const [tx, ty] = edgeTo(P1, noX);
    const keys: Key[] = [
      [t, 470, P1, 0],
      [t + s(0.15), 510, P1, 1],
      [t + s(0.55), 785, P1, 1],
      [t + s(0.65), 840, P1, 0],
      [t + s(0.65), fx, fy, 0],
      [t + s(0.72), mix(fx, tx, 0.1), mix(fy, ty, 0.1), 1],
      [t + s(1.1), tx, ty, 1],
      [t + s(1.2), tx, ty + 14, 0],
      [t + s(1.2), noX, P1 + DY + 44, 0],
      [t + s(1.3), noX, P1 + DY + 56, 1],
      [t + s(2.0), noX, P1 + DY + 190, 0],
    ];
    return { text, keys, edge: t + s(0.65), hit: t + s(1.15) };
  });

  // Phase 2: each declared value takes its own exit.
  const P2 = 650;
  const values = [
    { token: '"SAVE10"', text: "SAVE10", word: aMatch },
    { token: '"save10"', text: "save10", word: ciMatch },
    { token: '"NOPE"', text: "NOPE", word: noMatch },
  ].map((v, i) => {
    const t = v.word - s(0.3);
    const [px, py] = tokenAt(1, v.token);
    const ex = EXITS[i].x;
    const [fx, fy] = edgeFrom(P2, ex);
    const [tx, ty] = edgeTo(P2, ex);
    const keys: Key[] = [
      [t, px, py, 0],
      [t + s(0.1), px, py, 1],
      [t + s(0.38), 960, P2 - ROOT_H / 2 - 6, 1],
      [t + s(0.44), 960, P2 - 12, 0],
      [t + s(0.44), fx, fy, 0],
      [t + s(0.5), mix(fx, tx, 0.12), mix(fy, ty, 0.12), 1],
      [t + s(0.78), tx, ty, 1],
      [t + s(0.84), tx, ty + 14, 0],
      [t + s(0.84), ex, P2 + DY + 70, 0],
      [t + s(1.0), ex, P2 + DY + 82, 1],
    ];
    return { ...v, keys, edge: t + s(0.44), hit: t + s(0.8) };
  });

  // The spec card's lines: the three amendments tint on "three lines"; the one being read lights.
  const specAt = three + s(0.3);
  const specX = track(frame, fps, [[0, 960], [replaces, 560]], 0.7);
  const faint = [0, 1, 2].map((i) => span(threeLines + s(i * 0.15), call));
  const strong = [span(save, remove), span(remove, last), span(last, call)];
  const dimRest = span(rest, call);
  const lineOpacity = SPEC.map((_, i) => (SEAMS.includes(i) ? 0.35 : i === 3 ? 1 : 1 - 0.65 * dimRest));
  const washes = SPEC.map((_, i) => (i >= 1 && i <= 3 ? Math.max(0.45 * faint[i - 1], strong[i - 1]) * lineOpacity[i] : 0));
  const boxes = [
    { line: 1, token: '"code"', o: span(codeWord, save) },
    { line: 1, token: '"SAVE10"', o: span(save, remove) },
    { line: 1, token: '"save10"', o: span(lower, remove) },
    { line: 1, token: '"NOPE"', o: span(nope, remove) },
    { line: 2, token: '"sku"', o: span(product, rest) },
    { line: 2, token: "Catalog.skus", o: span(catalogue, rest) },
    { line: 3, token: ".last()", o: span(last, call) },
  ];

  // The catalogue's values, beneath the removeSku line.
  const skuX = tokenAt(2, "Catalog.skus")[0];
  const skuBump = pulse(frame, fps, catalogue, 0.5);
  const skuFade = visibility(frame, fps, undefined, rest);

  // The checkout row, recalled from the table; its badge flips on "it runs last".
  const rowO = span(checkout, rest, 0.5);
  const flip = prog(frame, last, 0.5, fps);
  const ROW2_Y = 770;

  return (
    <>
      {/* 1 · Strings stay pending. */}
      <PendingTable out={three} pendingAt={nothing} pulses={[strings, stays]} magicAt={magic} washIn={promo} washOut={so} />

      <Branch ry={P1} at={promo} out={so} lit={[undefined, undefined, randoms[0].edge]} hits={[[], [], randoms.map((r) => r.hit)]} />
      {randoms.map((r, i) => (
        <Mover key={i} text={r.text} keys={r.keys} out={so} />
      ))}
      <HollowPill x={1650} y={P1} at={green} crackAt={hollow} out={so} />

      <TrapCard x={960} y={640} at={traps} out={three} markAt={naming} />

      {/* 2 · The three lines. */}
      <CodeCard x={specX} y={SPEC_Y} w={SPEC_W} file="CartMigrationSpec.swift" lines={SPEC.map(() => "")} color={C.text} at={specAt} out={replaces} />
      <SpecLines x={specX} at={specAt} out={replaces} lineOpacity={lineOpacity} washes={washes} boxes={boxes} />

      <Branch ry={P2} at={amendPromo} out={remove} lit={values.map((v) => v.edge)} hits={values.map((v) => [v.hit])} />
      {values.map((v, i) => (
        <Mover key={i} text={v.text} keys={v.keys} out={remove} />
      ))}

      {skuFade > 0 && frame >= remove && (
        <div style={{ position: "absolute", left: skuX, top: 640, transform: "translate(-50%, -50%)", display: "flex", gap: 22, opacity: skuFade }}>
          {SKUS.map((sku, i) => {
            const p = prog(frame, remove + s(0.45 + i * 0.12), 0.4, fps);
            return (
              <div key={sku} style={{ ...chip(VALUE), opacity: p, transform: `translateY(${(1 - p) * -16}px) scale(${1 + 0.08 * skuBump})` }}>
                {sku}
              </div>
            );
          })}
        </div>
      )}

      {rowO > 0 && (
        <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, opacity: rowO }}>
          <div style={{ position: "absolute", left: TABLE_L, top: ROW2_Y - 30, width: TABLE_R - TABLE_L, height: 2, background: C.faint }} />
          <div style={{ position: "absolute", left: TABLE_L, top: ROW2_Y + 28, width: TABLE_R - TABLE_L, height: 2, background: C.faint }} />
          <Row
            y={ROW2_Y}
            row={ROWS[3]}
            badge={
              <>
                <Badge x={COL.badge} y={ROW2_Y} text="× 0…3" color={C.dim} sy={1 - 2 * flip} />
                <Badge x={COL.badge - 20} y={ROW2_Y} text="last · once" color={VALUE} sy={2 * flip - 1} />
              </>
            }
          />
        </div>
      )}

      {/* 3 · The rest of the ordering vocabulary. */}
      <Strip
        y={850}
        at={rest + s(0.3)}
        out={differ}
        items={[
          { code: ".once()", litAt: once },
          { code: ".repeating(_:)", litAt: repeat },
          { code: ".after(_:)", litAt: follow, tag: "soft", tagAt: breaks },
          { code: ".requires(_:)", litAt: requireOne, tag: "hard gate", tagAt: never, hard: true },
        ]}
      />

      {/* 4 · A full Op replaces its derived twin. */}
      <TwinChip x={1540} y={610} at={call} strikeAt={twin} />
      <CodeCard
        x={track(frame, fps, [[0, 1160], [replaces + s(0.2), 760]], 0.7)}
        y={REPLACE_Y}
        w={860}
        file="DerivedOpsTests.swift"
        lines={REPLACE}
        color={C.text}
        at={replaces + s(0.2)}
        marks={[1, 2, 3, 4, 5, 6, 7].map((line, i) => ({ line, at: replaces + s(0.6 + i * 0.04), color: VALUE }))}
      />
      <Svg>
        <Arrow from={[1215, REPLACE_Y + 11]} to={[1468, 606]} at={derived} dur={0.4} color={VALUE} width={3} />
      </Svg>
      <Text x={1340} y={545} size={SIZE} italic color={VALUE} at={derived} reveal="fade">
        replaces
      </Text>
    </>
  );
};
