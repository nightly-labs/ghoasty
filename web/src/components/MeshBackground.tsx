import { useEffect, useState } from 'react'
import { MeshGradient } from '@paper-design/shaders-react'

// Brand palette sampled from the Ghoasty app icon — deepened, with extra dark
// stops so the mesh stays moody rather than washing out the copy.
const COLORS = ['#08080c', '#7b5fe6', '#5f7cee', '#54c29c', '#d89a4c']

/**
 * WebGL mesh-gradient background (paper.design shader). Renders client-side only —
 * it uses a canvas, so returning null on the server and first client render keeps
 * hydration in sync. The CSS `.ghoasty-glow` sits underneath as the SSR fallback.
 */
export function MeshBackground() {
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  if (!mounted) return null

  return (
    <MeshGradient
      className="absolute inset-0 h-full w-full"
      width="100%"
      height="100%"
      colors={COLORS}
      distortion={0.85}
      swirl={0.18}
      speed={0.25}
    />
  )
}
