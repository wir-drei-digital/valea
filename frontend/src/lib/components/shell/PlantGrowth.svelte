<script lang="ts">
  // Calm easter egg for empty views: a small procedurally generated garden
  // that draws itself in — ink-green stems, unfurling leaves, one amber
  // bud, then an almost-imperceptible sway. A fresh arrangement grows on
  // every visit (generation runs once per mount).
  //
  // Purely decorative: the whole SVG is aria-hidden, and under
  // prefers-reduced-motion nothing animates — the garden simply stands
  // fully grown.

  type Point = { x: number; y: number };
  type Leaf = { x: number; y: number; angle: number; scale: number; delay: number; fill: string };
  type Stem = {
    d: string;
    len: number;
    delay: number;
    width: number;
    opacity: number;
    leaves: Leaf[];
    bud: { x: number; y: number; delay: number } | null;
  };

  const BASE_Y = 122;
  const GROW_S = 2.6; // stem draw-in duration; leaf delays ride along it

  function rand(min: number, max: number): number {
    return min + Math.random() * (max - min);
  }

  function quadPoint(p0: Point, p1: Point, p2: Point, t: number): Point {
    const u = 1 - t;
    return {
      x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
      y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y
    };
  }

  function quadTangentDeg(p0: Point, p1: Point, p2: Point, t: number): number {
    const dx = 2 * (1 - t) * (p1.x - p0.x) + 2 * t * (p2.x - p1.x);
    const dy = 2 * (1 - t) * (p1.y - p0.y) + 2 * t * (p2.y - p1.y);
    return (Math.atan2(dy, dx) * 180) / Math.PI;
  }

  function quadLength(p0: Point, p1: Point, p2: Point): number {
    let len = 0;
    let prev = p0;
    for (let i = 1; i <= 24; i++) {
      const pt = quadPoint(p0, p1, p2, i / 24);
      len += Math.hypot(pt.x - prev.x, pt.y - prev.y);
      prev = pt;
    }
    return len;
  }

  function makeStem(x0: number, height: number, delay: number, budded: boolean): Stem {
    const lean = rand(-16, 16);
    const p0 = { x: x0, y: BASE_Y };
    const p2 = { x: x0 + lean, y: BASE_Y - height };
    const p1 = {
      x: x0 + lean * rand(0.1, 0.5) + rand(-8, 8),
      y: BASE_Y - height * rand(0.45, 0.65)
    };

    const leaves: Leaf[] = [];
    const leafCount = Math.max(2, Math.round(height / 22));
    for (let k = 0; k < leafCount; k++) {
      const t = Math.min(0.92, 0.3 + (k / leafCount) * 0.6 + rand(-0.04, 0.04));
      const side = k % 2 === 0 ? 1 : -1;
      const pt = quadPoint(p0, p1, p2, t);
      leaves.push({
        x: pt.x,
        y: pt.y,
        angle: quadTangentDeg(p0, p1, p2, t) + side * rand(38, 60),
        scale: rand(0.6, 0.95) * (1 - t * 0.25),
        delay: delay + t * GROW_S * 0.92,
        fill: k % 2 === 0 ? 'var(--act-dot)' : 'var(--act)'
      });
    }

    return {
      d: `M ${p0.x} ${p0.y} Q ${p1.x} ${p1.y} ${p2.x} ${p2.y}`,
      len: Math.ceil(quadLength(p0, p1, p2)),
      delay,
      width: 1.6,
      opacity: 1,
      leaves,
      bud: budded ? { x: p2.x, y: p2.y - 1.5, delay: delay + GROW_S * 0.95 } : null
    };
  }

  /** Short leafless blades near the ground line — texture, not structure. */
  function makeBlade(x0: number, delay: number): Stem {
    const stem = makeStem(x0, rand(9, 16), delay, false);
    return { ...stem, leaves: [], width: 1.2, opacity: 0.55 };
  }

  function makeGarden(): Stem[] {
    const positions = Math.random() < 0.5 ? [84, 156] : [58, 120, 182];
    const buddedIndex = Math.floor(rand(0, positions.length));
    const stems = positions.map((baseX, i) =>
      makeStem(baseX + rand(-10, 10), rand(52, 92), i * 0.75 + rand(0, 0.35), i === buddedIndex)
    );
    const blades = [rand(38, 52), rand(104, 136), rand(190, 204)].map((x, i) =>
      makeBlade(x, rand(0.1, 0.5) + i * 0.3)
    );
    return [...stems, ...blades];
  }

  const garden = makeGarden();
</script>

<svg viewBox="0 0 240 130" class="h-[116px] w-[216px]" aria-hidden="true" focusable="false">
  <g class="sway">
    <path d="M26 {BASE_Y} H 214" stroke="var(--paper-chip-border)" stroke-width="1.5" stroke-linecap="round" fill="none" />
    {#each garden as stem, i (i)}
      <path
        class="stem"
        style={`--len:${stem.len}; --delay:${stem.delay}s`}
        d={stem.d}
        stroke="var(--act)"
        stroke-width={stem.width}
        stroke-linecap="round"
        fill="none"
        opacity={stem.opacity}
      />
      {#each stem.leaves as leaf, k (k)}
        <g transform={`translate(${leaf.x} ${leaf.y}) rotate(${leaf.angle})`}>
          <path
            class="leaf"
            style={`--s:${leaf.scale}; --delay:${leaf.delay}s`}
            d="M0 0 C5 -5, 12 -5.5, 15.5 -1 C12 3.5, 5 3.5, 0 0 Z"
            fill={leaf.fill}
            opacity="0.92"
          />
        </g>
      {/each}
      {#if stem.bud}
        <circle
          class="bud"
          style={`--delay:${stem.bud.delay}s`}
          cx={stem.bud.x}
          cy={stem.bud.y}
          r="2.6"
          fill="var(--suggest-dash)"
        />
      {/if}
    {/each}
  </g>
</svg>

<style>
  .stem {
    stroke-dasharray: var(--len);
    stroke-dashoffset: var(--len);
    animation: grow 2.6s cubic-bezier(0.25, 0.9, 0.3, 1) var(--delay) forwards;
  }

  .leaf {
    transform: scale(0);
    transform-origin: 0 0;
    animation: unfurl 0.8s cubic-bezier(0.2, 0.8, 0.3, 1) var(--delay) forwards;
  }

  .bud {
    opacity: 0;
    animation: bloom 0.6s ease-out var(--delay) forwards;
  }

  .sway {
    transform-origin: 50% 100%;
    animation: sway 8s ease-in-out 3.4s infinite alternate;
  }

  @keyframes grow {
    to {
      stroke-dashoffset: 0;
    }
  }

  @keyframes unfurl {
    to {
      transform: scale(var(--s));
    }
  }

  @keyframes bloom {
    to {
      opacity: 1;
    }
  }

  @keyframes sway {
    from {
      transform: rotate(-0.7deg);
    }
    to {
      transform: rotate(0.8deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .stem,
    .leaf,
    .bud,
    .sway {
      animation: none;
    }
    .stem {
      stroke-dashoffset: 0;
    }
    .leaf {
      transform: scale(var(--s));
    }
    .bud {
      opacity: 1;
    }
  }
</style>
