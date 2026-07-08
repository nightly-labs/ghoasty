import { useMemo } from 'react'

const CHARS = '  ..::;;xX8#0Ð+='

// Deterministic hash → no Math.random(), so SSR and client render identically.
function seeded(x: number, y: number) {
  const n = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453
  return n - Math.floor(n)
}

/**
 * A faint monospace character field layered over the hero gradient.
 * Purely decorative: aria-hidden, non-interactive, unselectable.
 */
export function AsciiTexture({ cols = 200, rows = 80 }: { cols?: number; rows?: number }) {
  const text = useMemo(() => {
    const lines: string[] = []
    for (let y = 0; y < rows; y++) {
      let line = ''
      for (let x = 0; x < cols; x++) {
        // Brightness rises toward the top, matching where the glow sits.
        const bias = 1 - y / rows
        const v = seeded(x, y) * 0.7 + bias * 0.5
        line += CHARS[Math.min(CHARS.length - 1, Math.floor(v * CHARS.length))]
      }
      lines.push(line)
    }
    return lines.join('\n')
  }, [cols, rows])

  return (
    <pre
      aria-hidden="true"
      style={{
        WebkitMaskImage:
          'radial-gradient(70% 70% at 50% 42%, #000 0%, transparent 75%)',
        maskImage: 'radial-gradient(70% 70% at 50% 42%, #000 0%, transparent 75%)',
      }}
      className="pointer-events-none absolute inset-0 m-0 h-full w-full select-none overflow-hidden whitespace-pre font-mono text-[10px] leading-[11px] text-white/[0.11] mix-blend-screen"
    >
      {text}
    </pre>
  )
}
