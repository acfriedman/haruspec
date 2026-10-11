import React from "react";
import { useScene, Arrow, Fade, Svg, Text, C, FONT, mix, prog, track } from "#kit";
import { ROLE, TestCard, useAppear } from "./shared";

// Illustrative: no real file is shown. The legacy class is placeholder bars with one legible method,
// and the test card is not real API (shared.tsx says so).

const BARS = [0.62, 0.48, 0.8, 0.7, 0.36, -1, 0.74, 0.55];

/** A source file drawn as a card: a tab with the file name, a role-coloured header strip, and either
 *  placeholder bars (with one legible `checkout` line) or nothing. `x`/`y` are its centre. */
const FileCard: React.FC<{
  x: number;
  y: number;
  scale: number;
  file: string;
  color: string;
  bars: boolean;
  at: number;
  glow?: number;
}> = ({ x, y, scale, file, color, bars, at, glow = 0 }) => {
  const { frame, fps } = useScene();
  const o = useAppear(at);
  if (o <= 0) return null;
  const w = 820;
  const h = 520;
  return (
    <div
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        boxSizing: "border-box",
        borderRadius: 18,
        border: `3px solid ${color}`,
        background: C.surface,
        overflow: "hidden",
        opacity: o,
        transform: `scale(${scale * mix(0.94, 1, o)})`,
        boxShadow: glow > 0 ? `0 0 ${40 * glow}px ${color}` : "none",
      }}
    >
      <div style={{ height: 14, background: color }} />
      <div style={{ height: 58, display: "flex", alignItems: "center", padding: "0 28px", borderBottom: `2px solid ${color}55`, fontFamily: FONT.mono, fontSize: 28, color }}>{file}</div>
      <div style={{ padding: "26px 32px" }}>
        {bars
          ? BARS.map((width, i) => {
              const p = prog(frame, at + Math.round((0.15 + i * 0.07) * fps), 0.35, fps);
              return width < 0 ? (
                <div key={i} style={{ fontFamily: FONT.mono, fontSize: 30, lineHeight: "48px", color: C.text, opacity: p, whiteSpace: "pre" }}>
                  {"- (NSInteger)"}
                  <span style={{ color }}>checkout</span>
                  {" {"}
                </div>
              ) : (
                <div key={i} style={{ height: 48, display: "flex", alignItems: "center" }}>
                  <div style={{ height: 16, width: `${width * 100 * p}%`, borderRadius: 8, background: C.faint }} />
                </div>
              );
            })
          : null}
      </div>
    </div>
  );
};

export const ColdOpen: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const cart = cue("shopping cart class");
  const objc = cue("Objective-C");
  const port = cue("port it to Swift");
  const test = cue("start with a test");
  const stall = cue("stall on the first line");
  const nobody = cue("Nobody knows");
  const movedOn = cue("moved on");
  const today = cue("what it does today");
  const oracle = cue("the oracle problem");
  const writeDown = cue("nobody can write it down");

  // Both files sit side by side, then shrink into the top third to make room for the test.
  const scale = track(frame, fps, [[0, 1], [test, 0.5]], 0.8);
  const leftX = track(frame, fps, [[0, 490], [test, 480]], 0.8);
  const rightX = track(frame, fps, [[0, 1430], [test, 1440]], 0.8);
  const cardY = track(frame, fps, [[0, 500], [test, 240]], 0.8);
  const shrunk = prog(frame, test, 0.8, fps);

  return (
    <>
      <FileCard x={leftX} y={cardY} scale={scale} file="LegacyCart.m" color={ROLE.baseline} bars at={cart} />
      <Text x={490} y={810} size={30} italic color={C.dim} at={objc} out={test} reveal="fade">
        Objective-C · years old · works
      </Text>

      <FileCard x={rightX} y={cardY} scale={scale} file="Cart.swift" color={ROLE.candidate} bars={false} at={port + s(0.3)} />
      <Fade x={1430} y={540} anchor="center" at={port + s(0.6)} out={test}>
        <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 30, color: C.dim }}>empty, so far</div>
      </Fade>
      <Svg opacity={1 - shrunk}>
        <Arrow from={[912, 500]} to={[1008, 500]} at={port} dur={0.5} color={ROLE.candidate} width={4} />
      </Svg>
      <Svg opacity={shrunk}>
        <Arrow from={[700, 240]} to={[1220, 240]} at={test} dur={0.01} color={ROLE.candidate} width={4} opacity={0.8} />
      </Svg>

      <TestCard x={1180} y={600} at={test + s(0.4)} pulseAt={nobody} />
      <Text x={1180} y={760} size={28} italic color={ROLE.unknown} at={stall} out={oracle} reveal="fade">
        stuck on the first line
      </Text>
      <Text x={1180} y={808} size={28} italic color={C.dim} at={movedOn} out={oracle} reveal="fade">
        the people who decided: gone
      </Text>

      {/* What it does today: the only thing anyone knows. */}
      <Svg>
        <Arrow from={[440, 380]} to={[440, 555]} at={today} dur={0.5} color={ROLE.baseline} width={4} />
      </Svg>
      <Fade at={today + s(0.4)} x={440} y={600} anchor="center" rise={10}>
        <div
          style={{
            fontFamily: FONT.mono,
            fontSize: 26,
            color: ROLE.baseline,
            border: `2.5px solid ${ROLE.baseline}`,
            borderRadius: 999,
            padding: "6px 20px",
            background: `${ROLE.baseline}18`,
            whiteSpace: "nowrap",
          }}
        >
          total: whatever it returns today
        </div>
      </Fade>

      <Text x={960} y={880} size={68} color={C.text} at={oracle} dur={0.9}>
        the oracle problem
      </Text>
      <Text x={960} y={950} size={30} italic color={C.dim} at={writeDown} reveal="fade">
        expected value: unknown
      </Text>
    </>
  );
};
