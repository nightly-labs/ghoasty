import { useEffect, useState } from 'react'
import { AsciiTexture } from './AsciiTexture'
import { MeshBackground } from './MeshBackground'

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

function XGlyph() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-5 w-5 fill-current">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24h-6.66l-5.214-6.817-5.966 6.817H1.68l7.73-8.835L1.254 2.25h6.83l4.713 6.231 5.447-6.231zm-1.161 17.52h1.833L7.084 4.126H5.117l11.966 15.644z" />
    </svg>
  )
}

function TelegramGlyph() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-5 w-5 fill-current">
      <path d="M23.91 3.79 20.3 20.84c-.25 1.21-.98 1.5-2 .94l-5.5-4.07-2.66 2.57c-.3.3-.55.56-1.1.56-.72 0-.6-.27-.84-.95L6.3 13.7l-5.45-1.7c-1.18-.35-1.19-1.16.26-1.75l21.26-8.2c.97-.43 1.9.24 1.53 1.73z" />
    </svg>
  )
}

export function Hero() {
  // Play the staggered entrance on mount. SSR renders the pre-reveal state
  // (shown=false), matching the first client render → no hydration mismatch.
  const [shown, setShown] = useState(false)
  useEffect(() => setShown(true), [])

  return (
    <main className={`t-stagger relative min-h-screen overflow-hidden ${shown ? 'is-shown' : ''}`}>
      {/* WebGL mesh gradient (client), over a CSS-glow SSR fallback, + faint ASCII field. */}
      <div className="ghoasty-glow absolute inset-0" />
      <MeshBackground />
      {/* Dark scrim so the vivid mesh doesn't wash out the copy. */}
      <div className="absolute inset-0 bg-[#08080c]/25" />
      <AsciiTexture />
      {/* Vignette to seat the copy. */}
      <div className="absolute inset-0 bg-[radial-gradient(120%_100%_at_50%_45%,transparent_0%,rgba(8,8,12,0.6)_100%)]" />

      {/* Wordmark */}
      <header className="t-stagger-line t-stagger-line--1 absolute inset-x-0 top-0 z-10 flex items-center justify-center gap-2.5 p-6 sm:p-8">
        <img
          src="/app-icon.png"
          alt="Ghoasty"
          width={36}
          height={36}
          className="h-10 w-10 rounded-[11px] shadow-lg shadow-black/40"
        />
        <span className="text-xl font-semibold tracking-tight">Ghoasty</span>
      </header>

      {/* Social links */}
      <div className="t-stagger-line t-stagger-line--7 absolute bottom-0 right-0 z-10 flex items-center gap-4 p-6 sm:p-8">
        <a
          href="https://x.com/norbertbodziony"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="X (Twitter)"
          className="text-white/45 transition-colors hover:text-white"
        >
          <XGlyph />
        </a>
        <a
          href="https://t.me/norbertbodziony"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Telegram"
          className="text-white/45 transition-colors hover:text-white"
        >
          <TelegramGlyph />
        </a>
      </div>

      <div className="relative flex min-h-screen flex-col items-center justify-center px-6 py-24 text-center">
        <h1 className="text-5xl font-semibold leading-[0.95] tracking-tight sm:text-7xl lg:text-8xl">
          <span className="t-stagger-line t-stagger-line--2 block">Talk. It types.</span>
          <span className="t-stagger-line t-stagger-line--3 block text-white/60">
            Nothing leaves your Mac.
          </span>
        </h1>
        <p className="t-stagger-line t-stagger-line--4 mt-8 max-w-2xl text-lg text-balance text-white/60 sm:text-xl">
          On-device push-to-talk dictation for macOS. Hold, speak, release, transcribed
          locally in a blink and pasted right where your cursor is. Private by design, and
          we never sell your data.
        </p>

        <div className="t-stagger-line t-stagger-line--5 mt-11 flex flex-col items-center gap-3.5">
          <a
            href="https://updates.ghoasty.ai/Ghoasty.dmg"
            download
            className="group inline-flex items-center gap-2.5 rounded-full bg-white px-8 py-4.5 text-lg font-medium text-black transition-transform duration-150 hover:scale-[1.02] active:scale-[0.99]"
          >
            <AppleGlyph />
            Download for macOS
          </a>
          <span className="text-base text-white/40">Apple Silicon · macOS 13+ · free</span>
        </div>

        {/* Stats */}
        <dl className="t-stagger-line t-stagger-line--6 mt-20 flex justify-center gap-12 sm:gap-16">
          {STATS.map((s) => (
            <div key={s.label}>
              <dt className="font-mono text-4xl tabular-nums tracking-tight text-white sm:text-5xl">
                {s.value}
              </dt>
              <dd className="mt-1.5 text-base text-white/45">{s.label}</dd>
            </div>
          ))}
        </dl>
      </div>
    </main>
  )
}
