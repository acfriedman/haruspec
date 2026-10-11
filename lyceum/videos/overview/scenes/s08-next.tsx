import React from "react";
import { useScene, Text, C, FONT, mix, prog, track } from "#kit";
import { ROLE, TestCard, VERDICT, useAppear } from "./shared";

/** One of the three follow-up videos: a card with a title, a one-line subtitle and an accent below.
 *  `x`/`y` are its centre. */
const VideoCard: React.FC<{
  x: number;
  y: number;
  title: string;
  sub: string;
  color: string;
  at: number;
  dim: number;
  children?: React.ReactNode;
}> = ({ x, y, title, sub, color, at, dim, children }) => {
  const o = useAppear(at, undefined, 0.6);
  if (o <= 0) return null;
  const w = 520;
  const h = 340;
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
        opacity: o * mix(1, 0.25, dim),
        transform: `translateY(${(1 - o) * 24}px)`,
      }}
    >
      <div style={{ height: 12, background: color }} />
      <div style={{ padding: "26px 32px 0" }}>
        <div style={{ fontFamily: FONT.serif, fontSize: 52, color: C.text }}>{title}</div>
        <div style={{ fontFamily: FONT.serif, fontStyle: "italic", fontSize: 30, color: C.dim, marginTop: 6 }}>{sub}</div>
        <div style={{ marginTop: 26 }}>{children}</div>
      </div>
    </div>
  );
};

export const Next: React.FC = () => {
  const { frame, fps, cue } = useScene();

  const five = cue("Haruspec in five minutes");
  const three = cue("Three videos go deeper");
  const specs = cue("Specs");
  const write = cue("the one thing you write");
  const seams = cue("Seams");
  const unstable = cue("reads unstable");
  const verdicts = cue("And verdicts");
  const four = cue("the four answers");
  const block = cue("the block that qualifies them");
  const declare = cue("declare the change you meant");
  const finish = cue("that test we couldn't finish");
  const knew = cue("already knew");

  const dim = prog(frame, finish, 0.6, fps);
  const cardY = track(frame, fps, [[0, 560], [finish, 340]], 0.8);
  const chip = (text: string, color: string, t: number) => {
    const p = prog(frame, t, 0.45, fps);
    return (
      <span
        style={{
          display: "inline-block",
          fontFamily: FONT.mono,
          fontSize: 26,
          color,
          border: `2.5px solid ${color}`,
          borderRadius: 999,
          padding: "2px 16px",
          background: `${color}1E`,
          marginRight: 12,
          opacity: p,
          transform: `translateY(${(1 - p) * 10}px)`,
        }}
      >
        {text}
      </span>
    );
  };

  return (
    <>
      <Text x={960} y={190} size={60} color={C.text} at={five} dur={0.8} out={finish}>
        Haruspec in five minutes
      </Text>
      <Text x={960} y={262} size={32} italic color={C.dim} at={three} reveal="fade" out={finish}>
        three videos go deeper
      </Text>

      <VideoCard x={360} y={cardY} title="Specs" sub="the one thing you write" color={ROLE.seam} at={specs} dim={dim}>
        {frame >= write ? chip("Spec<Cart> { … }", C.text, write) : null}
      </VideoCard>
      <VideoCard x={960} y={cardY} title="Seams" sub="what the oracle controls" color={ROLE.baseline} at={seams} dim={dim}>
        {frame >= unstable ? chip(`${VERDICT.unstable.icon} UNSTABLE`, ROLE.unstable, unstable) : null}
      </VideoCard>
      <VideoCard x={1560} y={cardY} title="Verdicts" sub="the four answers, and the change you meant" color={ROLE.candidate} at={verdicts} dim={dim}>
        <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
          {(["equivalent", "diverged", "cannotVerify", "unstable"] as const).map((kind, i) => {
            const p = prog(frame, four + Math.round(i * 0.12 * fps), 0.35, fps);
            return <div key={kind} style={{ width: 30, height: 30, borderRadius: 999, background: VERDICT[kind].color, opacity: p, transform: `scale(${mix(0.4, 1, p)})` }} />;
          })}
          <div style={{ width: 4, height: 34, background: C.dim, marginLeft: 10, opacity: prog(frame, block, 0.4, fps) }} />
          <div style={{ fontFamily: FONT.mono, fontSize: 26, color: C.dim, opacity: prog(frame, block, 0.4, fps) }}>qualified</div>
        </div>
        <div style={{ marginTop: 14 }}>{frame >= declare ? chip("intent", ROLE.equivalent, declare) : null}</div>
      </VideoCard>

      <TestCard x={960} y={720} at={finish + Math.round(0.3 * fps)} answerAt={knew} answer="the old code" />
    </>
  );
};
