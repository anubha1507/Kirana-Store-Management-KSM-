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
  },
  preview: {
    host: 'localhost',
    port: 4173,
  },
});
