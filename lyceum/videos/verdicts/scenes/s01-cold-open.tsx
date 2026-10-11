import React from "react";
import { useScene, Fade, Svg, Line, Text, C, FONT, LINE_HEIGHT, mix, prog, track } from "#kit";
import { CodeCard, ROLE, VERDICT, useAppear } from "./shared";

// The banner is quoted exactly from commit 90614a6's message (4 August 2026); today's report reads
// differently. The code is Tests/SpecTests/UnmatchedDomainTests.swift, simplified: the test's key
// parameter is written as the literal it is given ("qtyy"), other operations elided. The balance is
// illustrative.

const BANNER = "EQUIVALENT  ·  64 runs · all 1 ordering x 64 seam variants  ·  coverage: 100%";
const BANNER_SIZE = 30;
const BANNER_CHAR = BANNER_SIZE * 0.6;

const CODE = [
  'Op("add") { cart, seams in',
  '    cart.addItem(priceCents: 999, qty: Int(seams.int("qty", default: 2)))',
  "}",
  '.vary { Seam("qtyy", .int(1 ... 20)) }',
];
const CARD = { x: 960, y: 560, w: 1300, size: 26 };
const CARD_H = 52 + CODE.length * CARD.size * LINE_HEIGHT + 36;

/** Where `needle` sits in a line of the code card: its left edge, width and baseline. */
function inCode(line: number, needle: string) {
  const col = CODE[line].indexOf(needle);
  const char = CARD.size * 0.6;
  const left = CARD.x - CARD.w / 2 + 3 + 24 + col * char;
  const top = CARD.y - CARD_H / 2 + 3 + 52 + 18 + line * CARD.size * LINE_HEIGHT;
  return { left, width: needle.length * char, y: top + CARD.size * LINE_HEIGHT - 6 };
}

/** The big verdict pill, draining from green to grey from `drainAt`. */
const BigPill: React.FC<{ y: number; scale: number; drainAt: number; dim: number }> = ({ y, scale, drainAt, dim }) => {
  const { frame, fps } = useScene();
  const o = useAppear(0, undefined, 0.5);
  const drain = prog(frame, drainAt, 1.2, fps);
  const pill = (color: string, opacity: number) => (
    <div
      style={{
        position: "absolute",
        left: 960,
        top: y,
        transform: `translate(-50%, -50%) scale(${scale})`,
        fontFamily: FONT.mono,
        fontWeight: 600,
        fontSize: 64,
        color,
        border: `4px solid ${color}`,
        background: `${color}1E`,
        borderRadius: 999,
        padding: "10px 48px",
        whiteSpace: "nowrap",
        opacity: opacity * o,
        boxShadow: `0 0 ${36 * (1 - drain)}px ${color}66`,
      }}
    >
      {VERDICT.equivalent.icon} {VERDICT.equivalent.text}
    </div>
  );
  return (
    <div style={{ opacity: mix(1, 1, dim) }}>
      {pill(ROLE.equivalent, 1 - drain)}
      {drain > 0 ? pill(C.dim, drain) : null}
    </div>
  );
};

export const ColdOpen: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const real = cue("a real verdict");
  const august = cue("in August");
  const nothing = cue("almost nothing");
  const typo = cue("mistyped seam key");
  const neverRead = cue("nothing ever read it");
  const same = cue("the same input");
  const shrunk = cue("quietly shrunk");
  const hour = cue("costs you an hour");
  const ships = cue("ships a bug");
  const catastrophic = cue("one catastrophic outcome");
  const saw = cue("say what it saw");

  // The pill and banner rise to make room for the code.
  const pillY = track(frame, fps, [[0, 380], [typo, 190]], 0.8);
  const pillScale = track(frame, fps, [[0, 1], [typo, 0.72]], 0.8);
  const bannerY = track(frame, fps, [[0, 500], [typo, 285]], 0.8);
  const dimAll = prog(frame, saw, 0.7, fps);
  const rest = 1 - 0.8 * dimAll;

  const bannerLeft = 960 - (BANNER.length * BANNER_CHAR) / 2;
  const underline = (needle: string, at: number) => {
    const col = BANNER.indexOf(needle);
    const p = prog(frame, at, 0.5, fps);
    if (frame < at) return null;
    return (
      <div
        style={{
          position: "absolute",
          left: bannerLeft + col * BANNER_CHAR,
          top: bannerY + BANNER_SIZE * 0.72,
          width: needle.length * BANNER_CHAR * p,
          height: 4,
          background: ROLE.cannotVerify,
          opacity: rest,
        }}
      />
    );
  };

  // Sixty-four cassette tiles fan out, all one colour, then collapse into one.
  const tilesIn = prog(frame, same, 0.8, fps);
  const collapse = prog(frame, same + s(1.6), 0.8, fps);
  const tilesOut = 1 - prog(frame, hour, 0.5, fps);
  const tiles =
    frame >= same && tilesOut > 0
      ? Array.from({ length: 64 }, (_, i) => {
          const col = i % 32;
          const row = Math.floor(i / 32);
          const tx = mix(960, 960 + (col - 15.5) * 38, tilesIn * (1 - collapse));
          const ty = mix(900, 880 + row * 34, tilesIn * (1 - collapse));
          return <rect key={i} x={tx - 14} y={ty - 11} width={28} height={22} rx={4} fill={`${ROLE.seam}55`} stroke={ROLE.seam} strokeWidth={2} opacity={tilesIn * tilesOut * rest} />;
        })
      : null;

  // The balance: a false red is light, a false green drops hard.
  const tilt = track(frame, fps, [[0, 0], [hour, -4], [ships, 13]], 0.6);
  const rad = (tilt * Math.PI) / 180;
  const pivot = { x: 960, y: 820 };
  const arm = 380;
  const left = { x: pivot.x - arm * Math.cos(rad), y: pivot.y - arm * Math.sin(rad) };
  const right = { x: pivot.x + arm * Math.cos(rad), y: pivot.y + arm * Math.sin(rad) };
  const balance = useAppear(hour, undefined, 0.5) * rest;
  const relabel = prog(frame, catastrophic, 0.5, fps);

  return (
    <>
      <BigPill y={pillY} scale={pillScale} drainAt={nothing} dim={dimAll} />

      <Fade x={960} y={bannerY} anchor="center" at={real} rise={0}>
        <div style={{ fontFamily: FONT.mono, fontSize: BANNER_SIZE, color: C.text, whiteSpace: "pre", opacity: rest }}>{BANNER}</div>
      </Fade>
      <Text x={1840} y={bannerY + 48} size={26} italic color={C.dim} anchor="right" at={august} reveal="fade" style={{ opacity: rest }}>
        August 2026 · the report has changed since
      </Text>
      {/* Amber underlines when the narration says why each claim was false. */}
      {underline("64 seam variants", same)}
      {underline("coverage: 100%", shrunk)}

      <div style={{ opacity: rest * (1 - prog(frame, hour, 0.5, fps)) }}>
        <CodeCard x={CARD.x} y={CARD.y} w={CARD.w} file="Tests/SpecTests/UnmatchedDomainTests.swift" lines={CODE} color={C.text} size={CARD.size} at={typo} />
        <Text x={1610} y={CARD.y - CARD_H / 2 - 22} size={26} italic color={C.dim} anchor="right" at={typo + s(0.4)} reveal="fade">
          simplified
        </Text>
        {frame >= typo + s(0.6) &&
          [inCode(1, '"qty"'), inCode(3, '"qtyy"')].map((u, i) => (
            <div
              key={i}
              style={{
                position: "absolute",
                left: u.left,
                top: u.y,
                width: u.width * prog(frame, typo + s(0.6 + i * 0.3), 0.4, fps),
                height: 4,
                background: ROLE.cannotVerify,
              }}
            />
          ))}
        <Svg>
          {(() => {
            const a = inCode(1, '"qty"');
            const b = inCode(3, '"qtyy"');
            return (
              <Line from={[a.left + a.width / 2, a.y + 8]} to={[b.left + b.width / 2, b.y - 34]} at={neverRead} dur={0.6} color={ROLE.cannotVerify} dashed width={3} />
            );
          })()}
        </Svg>
        {(() => {
          const a = inCode(1, '"qty"');
          const b = inCode(3, '"qtyy"');
          const p = prog(frame, neverRead + s(0.6), 0.4, fps);
          const mx = (a.left + a.width / 2 + b.left + b.width / 2) / 2;
          const my = (a.y + 8 + b.y - 34) / 2;
          return frame >= neverRead + s(0.6) ? (
            <div style={{ position: "absolute", left: mx, top: my, transform: `translate(-50%, -50%) scale(${mix(0.4, 1, p)})`, fontFamily: FONT.mono, fontSize: 34, fontWeight: 700, color: ROLE.diverged, opacity: p }}>
              ✕
            </div>
          ) : null;
        })()}
      </div>

      <Svg>{tiles}</Svg>
      <Text x={960} y={960} size={26} italic color={C.dim} at={same + s(1.6)} out={hour} reveal="fade">
        64 variants, one input
      </Text>

      {balance > 0 && (
        <>
          <Svg opacity={balance}>
            <line x1={pivot.x} y1={pivot.y} x2={pivot.x - 70} y2={pivot.y + 150} stroke={C.dim} strokeWidth={4} />
            <line x1={pivot.x} y1={pivot.y} x2={pivot.x + 70} y2={pivot.y + 150} stroke={C.dim} strokeWidth={4} />
            <line x1={left.x} y1={left.y} x2={right.x} y2={right.y} stroke={C.text} strokeWidth={5} />
            <circle cx={pivot.x} cy={pivot.y} r={8} fill={C.text} />
            {[
              { p: left, color: ROLE.cannotVerify },
              { p: right, color: ROLE.diverged },
            ].map(({ p, color }, i) => (
              <g key={i}>
                <line x1={p.x} y1={p.y} x2={p.x - 70} y2={p.y + 70} stroke={C.dim} strokeWidth={2} />
                <line x1={p.x} y1={p.y} x2={p.x + 70} y2={p.y + 70} stroke={C.dim} strokeWidth={2} />
                <path d={`M ${p.x - 80} ${p.y + 70} Q ${p.x} ${p.y + 110} ${p.x + 80} ${p.y + 70}`} fill="none" stroke={color} strokeWidth={4} />
              </g>
            ))}
          </Svg>
          <div style={{ position: "absolute", left: left.x, top: left.y + 112, transform: "translateX(-50%)", fontFamily: FONT.serif, fontSize: 30, color: ROLE.cannotVerify, whiteSpace: "nowrap", opacity: balance }}>
            a false red: an hour
          </div>
          <div style={{ position: "absolute", left: right.x, top: right.y + 112, transform: "translateX(-50%)", fontFamily: FONT.serif, fontSize: 30, color: ROLE.diverged, whiteSpace: "nowrap", opacity: balance * prog(frame, ships, 0.4, fps) * (1 - relabel) }}>
            a false green: a shipped bug
          </div>
          <div style={{ position: "absolute", left: right.x, top: right.y + 112, transform: "translateX(-50%)", fontFamily: FONT.mono, fontSize: 30, fontWeight: 600, color: ROLE.diverged, whiteSpace: "nowrap", opacity: balance * relabel }}>
            a false EQUIVALENT
          </div>
        </>
      )}
    </>
  );
};
