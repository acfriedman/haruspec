import React from "react";
import { useScene, Arrow, Fade, Svg, Text, C, FONT, mix, prog } from "#kit";
import { CodeCard, ROLE, VERDICT, useAppear } from "./shared";

// The fixture is MintingSubject.total() in Tests/SpecTests/StabilityTests.swift (lines 71–73), with its
// dictionary broken over lines. The report lines are real (Stability.swift, UncontrolledSeam.swift,
// asserted in StabilityTests.swift), abridged. The two identifiers are illustrative.

const CODE = [
  "func total() {",
  "    center.post(",
  '        name: .init("Total"),',
  "        object: nil,",
  '        userInfo: ["value": 42, "orderID": UUID().uuidString]',
  "    )",
  "}",
];

const REPORT = [
  { text: "🌀 UNSTABLE", color: ROLE.unstable },
  { text: "  stability: the baseline disagreed with itself on the failing input", color: C.text },
  { text: "  uncontrolled seams — values the subject makes up itself:", color: C.text },
  { text: "    Total.orderID (UUID): a fresh identifier — inject its source", color: C.text, field: true },
  { text: "      (a `() -> UUID` the initializer takes, supplied by the spec's `.provides`)", color: C.dim },
];

const COL = { baseline: 1290, candidate: 1640 } as const;

/** One side of the check: a box with its role and the subject's type, and a later baseline overlay. */
const Side: React.FC<{ x: number; role: "baseline" | "candidate"; at: number; pulseAt: number; turnBlueAt?: number }> = ({
  x,
  role,
  at,
  pulseAt,
  turnBlueAt,
}) => {
  const { frame, fps } = useScene();
  const o = useAppear(at);
  if (o <= 0) return null;
  const blue = turnBlueAt === undefined ? 0 : prog(frame, turnBlueAt, 0.6, fps);
  const pulse = frame >= pulseAt ? Math.max(0, Math.sin(((frame - pulseAt) / fps) * Math.PI * 1.6)) * (frame - pulseAt < 1.3 * fps ? 1 : 0) : 0;
  const box = (color: string, label: string, opacity: number) => (
    <div
      style={{
        position: "absolute",
        left: x - 150,
        top: 270,
        width: 300,
        height: 150,
        boxSizing: "border-box",
        borderRadius: 16,
        border: `3px solid ${color}`,
        background: `linear-gradient(180deg, ${color}1C, ${color}08)`,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 10,
        opacity,
      }}
    >
      <div style={{ fontFamily: FONT.serif, fontSize: 34, color }}>{label}</div>
      <div style={{ fontFamily: FONT.mono, fontSize: 26, color: pulse > 0.05 ? C.text : C.dim, textShadow: pulse > 0 ? `0 0 ${16 * pulse}px ${color}` : "none" }}>
        MintingSubject
      </div>
    </div>
  );
  const color = role === "baseline" ? ROLE.baseline : ROLE.candidate;
  return (
    <div style={{ opacity: o }}>
      {box(color, role, 1 - blue)}
      {blue > 0 ? box(ROLE.baseline, "baseline", blue) : null}
    </div>
  );
};

/** The payload a side posts: `value 42`, and an identifier it made up. */
const Payload: React.FC<{ x: number; id: string; color: string; at: number }> = ({ x, id, color, at }) => (
  <Fade x={x} y={505} anchor="center" at={at} rise={10}>
    <div
      style={{
        fontFamily: FONT.mono,
        fontSize: 26,
        lineHeight: "38px",
        color: C.text,
        border: `2.5px solid ${color}`,
        borderRadius: 14,
        padding: "6px 16px",
        background: C.surface,
        whiteSpace: "nowrap",
      }}
    >
      <div>value 42</div>
      <div>
        orderID <span style={{ color: ROLE.unstable }}>{id}</span>
      </div>
    </div>
  </Fade>
);

export const ColdOpen: React.FC = () => {
  const { frame, fps, cue } = useScene();
  const s = (sec: number) => Math.round(sec * fps);

  const check = cue("a check that should be boring");
  const both = cue("The baseline and the candidate");
  const sameClass = cue("the same class");
  const inputs = cue("identical inputs");
  const unstable = cue("It says unstable");
  const posts = cue("what the class posts");
  const total = cue("a total of forty-two");
  const spot = cue("on the spot");
  const agree = cue("agree with itself");
  const saysSo = cue("says so", { after: agree });
  const field = cue("names the field");

  const banner = prog(frame, unstable + s(0.3), 0.5, fps);
  const glow = (t: number) => (frame >= t ? 0.5 + 0.5 * Math.sin(((frame - t) / fps) * Math.PI * 2 * 0.8) : 0);

  return (
    <>
      <CodeCard
        x={580}
        y={330}
        w={1000}
        file="StabilityTests.swift"
        lines={CODE}
        color={C.text}
        at={check}
        marks={[
          { line: 1, at: posts, color: C.text },
          { line: 4, at: total, color: ROLE.seam },
          { line: 4, at: spot, color: ROLE.unstable },
        ]}
      />
      <Text x={1000} y={128} size={26} italic color={C.dim} at={check + s(0.4)} reveal="fade">
        reformatted
      </Text>
      {/* `UUID().uuidString` glows violet once the narration names the made-up identifier. */}
      <Fade x={910} y={396} anchor="center" at={spot} rise={0}>
        <div style={{ width: 284, height: 40, borderRadius: 8, border: `2.5px solid ${ROLE.unstable}`, boxShadow: `0 0 ${24 * glow(spot)}px ${ROLE.unstable}` }} />
      </Fade>

      <Side x={COL.baseline} role="baseline" at={both} pulseAt={sameClass} />
      <Side x={COL.candidate} role="candidate" at={both + s(0.4)} pulseAt={sameClass} turnBlueAt={agree} />
      <Text x={1640} y={240} size={26} italic color={ROLE.baseline} at={agree + s(0.4)} reveal="fade">
        baseline against baseline
      </Text>

      <Fade x={1465} y={160} anchor="center" at={inputs} rise={6} out={agree}>
        <div style={{ fontFamily: FONT.serif, fontSize: 28, color: C.text, background: C.faint, borderRadius: 10, padding: "6px 28px", whiteSpace: "nowrap" }}>identical inputs</div>
      </Fade>
      <Svg>
        <Arrow from={[1400, 190]} to={[COL.baseline, 262]} at={inputs + s(0.3)} out={agree} dur={0.5} color={C.dim} />
        <Arrow from={[1530, 190]} to={[COL.candidate, 262]} at={inputs + s(0.3)} out={agree} dur={0.5} color={C.dim} />
      </Svg>

      <Payload x={COL.baseline} id="3F2C9A1E-…" color={ROLE.baseline} at={total} />
      <Payload x={COL.candidate} id="9B07D4C2-…" color={ROLE.candidate} at={total + s(0.2)} />
      <Text x={1465} y={590} size={26} italic color={C.dim} at={total + s(0.6)} reveal="fade">
        identifiers illustrative
      </Text>

      {/* The verdict drops across both sides. */}
      {banner > 0 && (
        <div
          style={{
            position: "absolute",
            left: 1120,
            top: mix(200, 395, banner),
            width: 690,
            height: 50,
            borderRadius: 12,
            background: `${ROLE.unstable}E6`,
            color: C.bg,
            fontFamily: FONT.mono,
            fontWeight: 700,
            fontSize: 32,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            opacity: banner * (frame >= saysSo ? 1 - prog(frame, saysSo, 0.5, fps) : 1),
          }}
        >
          {VERDICT.unstable.icon} {VERDICT.unstable.text}
        </div>
      )}

      {/* The report: abridged, real lines. */}
      <Fade x={960} y={800} anchor="center" at={saysSo} rise={40}>
        <div
          style={{
            width: 1760,
            boxSizing: "border-box",
            borderRadius: 16,
            border: `3px solid ${ROLE.unstable}`,
            background: C.surface,
            padding: "18px 30px 22px",
            position: "relative",
          }}
        >
          <div style={{ position: "absolute", right: 24, top: 14, fontFamily: FONT.serif, fontStyle: "italic", fontSize: 26, color: C.dim }}>abridged</div>
          {REPORT.map((row, i) => (
            <div
              key={i}
              style={{
                fontFamily: FONT.mono,
                fontSize: 26,
                lineHeight: "42px",
                whiteSpace: "pre",
                color: row.color,
                fontWeight: i === 0 ? 700 : 400,
              }}
            >
              {row.field ? (
                <>
                  {"    "}
                  <span style={{ color: ROLE.unstable, textShadow: `0 0 ${18 * glow(field)}px ${ROLE.unstable}` }}>Total.orderID</span>
                  {row.text.slice(4 + "Total.orderID".length)}
                </>
              ) : (
                row.text
              )}
            </div>
          ))}
        </div>
      </Fade>
    </>
  );
};
