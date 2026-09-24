import { createServer } from 'node:http';
import { app } from './app.js';
import { env } from './config/env.js';

const server = createServer(app);
const port = Number(process.env.PORT) || env.port || 5000;

server.listen(port, () => {
  console.log(`Backend listening on http://localhost:${port}`);
  console.log(`Health: http://localhost:${port}/health`);
  console.log(`API:   http://localhost:${port}/api`);
});

export { app, server };
