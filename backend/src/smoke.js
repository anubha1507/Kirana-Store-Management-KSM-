// Smoke entry for local development without a real database.
// Usage: node src/smoke.js
import { config } from 'dotenv';
import { createServer } from 'node:http';
import app from './app.js';

config();

const dbUrl = process.env.DATABASE_URL;
if (!dbUrl) {
  console.warn('DATABASE_URL missing; backend will start but DB-dependent routes will fail.');
}

const server = createServer(app);
const port = Number(process.env.PORT) || 5000;

server.listen(port, () => {
  console.log(`Smoke backend listening on http://localhost:${port}`);
});

