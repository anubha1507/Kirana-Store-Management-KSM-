import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

export function loadEnv() {
  // Keep for backward compatibility; env.js already loads dotenv on import.
  try {
    require('dotenv').config();
  } catch {
    // dotenv is optional at runtime if env vars are provided by the host.
  }
}

