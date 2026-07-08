import { useEffect, useRef } from 'react'

const COLS = 240
const ROWS = 90
const CELLS = COLS * ROWS
const GLYPHS = '·.:;xX08#=+-'

// Deterministic hash → SSR and first client render produce the same field (no hydration mismatch).
function seeded(x: number, y: number) {
  const n = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453
  return n - Math.floor(n)
}

// Dense static scatter. Shared by the SSR render and the animation's rest state.
function baseField() {
  const buf: string[] = new Array(CELLS)
  for (let y = 0; y < ROWS; y++) {
    for (let x = 0; x < COLS; x++) {
      const v = seeded(x, y)
      buf[y * COLS + x] = v > 0.42 ? GLYPHS[Math.floor(seeded(y, x) * GLYPHS.length)] : ' '
    }
  }
  return buf
}

function render(buf: string[]) {
  const lines: string[] = new Array(ROWS)
  for (let y = 0; y < ROWS; y++) lines[y] = buf.slice(y * COLS, y * COLS + COLS).join('')
  return lines.join('\n')
}

const STATIC = render(baseField())

export function AsciiTexture() {
  const ref = useRef<HTMLPreElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return

    const buf = baseField()
    const rnd = () => Math.random()
    const TWINKLE = Math.round(CELLS * 0.008) // ~170 cells/tick → gentle shimmer

    const tick = () => {
      for (let n = 0; n < TWINKLE; n++) {
        const idx = Math.floor(rnd() * CELLS)
        buf[idx] = rnd() > 0.45 ? GLYPHS[Math.floor(rnd() * GLYPHS.length)] : ' '
      }
      el.textContent = render(buf)
    }

    const id = window.setInterval(tick, 90)
    return () => window.clearInterval(id)
  }, [])

  return (
    <pre
      ref={ref}
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 m-0 select-none overflow-hidden whitespace-pre font-mono text-[11px] leading-[16px] tracking-[0.12em] text-white/[0.16] mix-blend-screen"
    >
      {STATIC}
    </pre>
  )
}
