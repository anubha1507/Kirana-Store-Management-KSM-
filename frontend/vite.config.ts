import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The dev server binds to localhost so the app can be opened at
// http://localhost:5173 after `npm run dev`.
export default defineConfig({
  plugins: [react()],
  server: {
    host: 'localhost',
    port: 5173,
    strictPort: true,
    // Single-origin dev setup: browser calls `/api/...` on this same origin
    // and Vite forwards it to the Express backend, so frontend + backend are
    // reachable from one localhost link (http://localhost:5173) with no CORS.
    proxy: {
      '/api': 'http://localhost:5000',
      '/health': 'http://localhost:5000',
    },
  },
  preview: {
    host: 'localhost',
    port: 4173,
  },
});
