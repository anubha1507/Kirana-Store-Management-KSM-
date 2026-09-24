import jwt from 'jsonwebtoken';
import { env } from '../config/env.js';

const ALGORITHM = 'HS256';

// Stateless HS256 session tokens (8h). The DB access layer lives in
// src/models/*; this module only mints and verifies tokens.
export async function createSessionToken(userId, role = 'cashier', storeId = null, email = null) {
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    sub: userId,
    role,
    storeId,
    email,
    aud: env.jwtAudience,
    iss: env.jwtIssuer,
    iat: now,
    exp: now + 60 * 60 * 8, // 8 hours
  };
  return jwt.sign(payload, env.jwtSecret, { algorithm: ALGORITHM });
}

export function verifySessionToken(token) {
  const decoded = jwt.verify(token, env.jwtSecret, {
    algorithms: [ALGORITHM],
    issuer: env.jwtIssuer,
    audience: env.jwtAudience,
  });
  return decoded;
}