import { defineConfig } from 'vite'
import { devtools } from '@tanstack/devtools-vite'

import { tanstackStart } from '@tanstack/react-start/plugin/vite'

import viteReact from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { nitro } from 'nitro/vite'

const config = defineConfig({
  resolve: { tsconfigPaths: true },
  plugins: [
    devtools(),
    nitro({
      preset: process.env.NITRO_PRESET ?? 'cloudflare-module',
      rollupConfig: { external: [/^@sentry\//] },
      // Serve the DMG through our own worker so the download always gets a
      // proper filename. Cross-origin links ignore the HTML `download` attr,
      // and R2 sends no Content-Disposition — proxying lets us inject it.
      routeRules: {
        '/download/Ghoasty.dmg': {
          proxy: 'https://dl.ghoasty.ai/Ghoasty.dmg',
          headers: { 'content-disposition': 'attachment; filename="Ghoasty.dmg"' },
        },
      },
    }),
    tailwindcss(),
    tanstackStart(),
    viteReact(),
  ],
})

export default config
