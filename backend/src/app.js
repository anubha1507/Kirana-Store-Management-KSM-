import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import { env } from './config/env.js';
import { db } from './config/db.js';
import { router } from './routes/index.js';
import { errorHandler, notFoundHandler } from './middleware/error.js';

const app = express();

app.use(helmet({ contentSecurityPolicy: false }));
// CORS: only the frontend dev/preview origins listed in FRONTEND_URL
// (comma-separated, default http://localhost:5173). Requests without an
// Origin header (curl, health checks) are allowed.
const allowedOrigins = env.frontendUrl
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
app.use(
  cors({
    origin: (origin, callback) => callback(null, !origin || allowedOrigins.includes(origin)),
    credentials: true,
  })
);
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

app.get('/health', async (_req, res) => {
  try {
    const { rowCount } = await db.query('SELECT 1 AS ok');
    if (!rowCount || rowCount !== 1) {
      return res.status(503).json({ success: false, status: 'degraded', db: 'unreachable' });
    }
    return res.json({ success: true, status: 'ok', db: 'connected', env: env.nodeEnv });
  } catch (error) {
    console.error('Health check failed:', error);
    return res.status(503).json({ success: false, status: 'error', error: String(error) });
  }
});

app.use('/api', router);

app.use(notFoundHandler);
app.use(errorHandler);

export { app };
export default app;

