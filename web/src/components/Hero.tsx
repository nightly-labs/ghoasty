import { AsciiTexture } from './AsciiTexture'

const STATS = [
  { value: '100%', label: 'on-device' },
  { value: '~10×', label: 'faster' },
  { value: '$0', label: 'data sold' },
]

function AppleGlyph() {
  return (
    <svg viewBox="0 0 384 512" aria-hidden="true" className="h-[1.05em] w-[1.05em] fill-current">
      <path d="M318.7 268c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141 4 184.6 4 273.5q0 39.4 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-92.6zM255.2 90.2c30.6-36.3 27.8-69.4 26.9-81.2-26.9 1.6-58 18.3-75.7 39-19.5 22-30.7 49.2-28.3 78.4 29.1 2.3 55.6-12.6 77.1-36.2z" />
    </svg>
  )
}

export function Hero() {
  return (
    <main className="relative min-h-screen overflow-hidden">
      {/* Iridescent gradient glow + faint ASCII field. */}
      <div className="ghoasty-glow absolute inset-0" />
      <AsciiTexture />
      {/* Vignette to seat the copy. */}
      <div className="absolute inset-0 bg-[radial-gradient(120%_90%_at_50%_0%,transparent_35%,rgba(8,8,12,0.65)_100%)]" />

      {/* Wordmark */}
      <header className="absolute inset-x-0 top-0 z-10 flex items-center justify-center gap-2.5 p-6 sm:p-8">
        <img
          src="/app-icon.png"
          alt="Ghoasty"
          width={36}
          height={36}
          className="h-9 w-9 rounded-[10px] shadow-lg shadow-black/40"
        />
        <span className="text-lg font-semibold tracking-tight">Ghoasty</span>
      </header>

      <div className="relative flex min-h-screen flex-col items-center justify-center px-6 py-24 text-center">
        <h1 className="text-5xl font-semibold leading-[0.95] tracking-tight sm:text-7xl lg:text-8xl">
          Talk. It types.
          <br />
          <span className="text-white/60">Nothing leaves your Mac.</span>
        </h1>
        <p className="mt-6 max-w-xl text-base text-balance text-white/60 sm:text-lg">
          On-device push-to-talk dictation for macOS. Hold, speak, release — transcribed
          locally in a blink and pasted right where your cursor is. Private by design, and
          we never sell your data.
        </p>

        <div className="mt-9 flex flex-col items-center gap-3">
          <a
            href="#"
            className="group inline-flex items-center gap-2.5 rounded-full bg-white px-6 py-3.5 text-base font-medium text-black transition-transform duration-150 hover:scale-[1.02] active:scale-[0.99]"
          >
            <AppleGlyph />
            Download for macOS
          </a>
          <span className="text-sm text-white/40">Apple Silicon · macOS 13+ · free</span>
        </div>

        {/* Stats */}
        <dl className="mt-16 flex justify-center gap-10 sm:gap-14">
          {STATS.map((s) => (
            <div key={s.label}>
              <dt className="font-mono text-3xl tabular-nums tracking-tight text-white sm:text-4xl">
                {s.value}
              </dt>
              <dd className="mt-1 text-sm text-white/45">{s.label}</dd>
            </div>
          ))}
        </dl>
      </div>
    </main>
  )
}
