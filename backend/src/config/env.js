import { createRequire } from 'node:module';
import { config } from 'dotenv';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const possibleEnvPaths = [
  join(__dirname, '..', '..', '.env'),
  join(__dirname, '..', '..', '.env.local'),
  join(__dirname, '..', '..', '.env.example'),
];

let loadedFrom = null;
for (const envPath of possibleEnvPaths) {
  if (existsSync(envPath)) {
    config({ path: envPath });
    loadedFrom = envPath;
    break;
  }
}

function getRequired(name, fallback = undefined) {
  const value = process.env[name];
  if (value === undefined || value === '') {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

export const env = {
  port: Number(process.env.PORT) || 5000,
  nodeEnv: process.env.NODE_ENV || 'development',
  frontendUrl: process.env.FRONTEND_URL || 'http://localhost:5173',
  jwtSecret: getRequired('JWT_SECRET'),
  jwtIssuer: getRequired('JWT_ISSUER', 'http://localhost:5000/api'),
  jwtAudience: getRequired('JWT_AUDIENCE', 'kirana-store-admin'),
  databaseUrl: process.env.DATABASE_URL || '',
  loadedFrom,
};

if (env.nodeEnv === 'development' && env.loadedFrom === null) {
  console.warn('Warning: No .env file loaded. Copy backend/.env.example to backend/.env.');
}
