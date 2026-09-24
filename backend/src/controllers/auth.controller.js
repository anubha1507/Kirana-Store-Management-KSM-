import { randomUUID } from 'node:crypto';
import bcrypt from 'bcryptjs';
import { withAuth } from '../config/db.js';
import * as userModel from '../models/user.model.js';
import { createSessionToken, verifySessionToken } from '../utils/auth.js';

// POST /api/auth/signup
// Creates the account and provisions its first store in ONE transaction:
// migration 028 mirrors the row into auth.users (shadow) and create_store's
// bootstrap trigger adds owner membership + default store settings, so the
// user can immediately use every store-scoped RPC.
export async function signup(req, res, next) {
  try {
    const { email, password, fullName, role = 'cashier', store_name } = req.body;

    const existing = await userModel.findByEmail(email);
    if (existing) {
      return res.status(409).json({ success: false, message: 'Email already registered' });
    }

    const passwordHash = await bcrypt.hash(password, 10);
    const id = randomUUID();

    const user = await withAuth({ id, email, role, storeId: null }, async (client) => {
      const created = await userModel.insert(client, {
        id, email, fullName, passwordHash, role,
      });
      const firstWord = String(fullName).trim().split(/\s+/)[0] || 'My';
      const storeLabel = (store_name && store_name.trim()) || `${firstWord}'s Store`;
      const { rows } = await client.query(`SELECT public.create_store($1) AS store`, [storeLabel]);
      const storeId = rows[0]?.store?.id ?? null;
      if (!storeId) return created;
      return (await userModel.setStore(client, id, storeId)) || created;
    });

    const token = await createSessionToken(user.id, user.role, user.store_id, user.email);
    res.status(201).json({
      success: true,
      data: { token, user: userModel.toPublic(user) },
    });
  } catch (error) {
    next(error);
  }
}

// POST /api/auth/login
export async function login(req, res, next) {
  try {
    const { email, password } = req.body;

    const user = await userModel.findByEmail(email);
    if (!user || user.is_active === false) {
      return res.status(401).json({ success: false, message: 'Invalid email or password' });
    }

    const isValid = await bcrypt.compare(password, user.password_hash || '');
    if (!isValid) {
      return res.status(401).json({ success: false, message: 'Invalid email or password' });
    }

    await userModel.touchLastLogin(user.id);
    const token = await createSessionToken(user.id, user.role, user.store_id, user.email);

    res.json({
      success: true,
      data: { token, user: userModel.toPublic(user) },
    });
  } catch (error) {
    next(error);
  }
}

// POST /api/auth/logout
// JWTs are stateless: the client discards its token (see frontend/src/lib/auth.ts)
// and the server acknowledges. The token simply expires on its own after 8h.
export async function logout(_req, res) {
  res.json({ success: true, data: { message: 'Signed out.' } });
}

// POST /api/auth/refresh  (requires a still-valid Bearer token)
export async function refresh(req, res, next) {
  try {
    const user = await userModel.findById(req.user.id);
    if (!user) {
      return res.status(401).json({ success: false, message: 'User not found' });
    }
    const token = await createSessionToken(user.id, user.role, user.store_id, user.email);
    res.json({
      success: true,
      data: { token, user: userModel.toPublic(user) },
    });
  } catch (error) {
    next(error);
  }
}

// GET /api/auth/me
export async function me(req, res, next) {
  try {
    const user = await userModel.findById(req.user.id);
    if (!user) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    res.json({ success: true, data: userModel.toPublic(user) });
  } catch (error) {
    next(error);
  }
}

// GET /api/auth/validate — lightweight token probe (200 + valid flag either way).
export async function validate(req, res, next) {
  try {
    const header = req.headers.authorization || '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) {
      return res.json({ success: true, data: { valid: false, message: 'No token provided' } });
    }

    let decoded = null;
    try {
      decoded = verifySessionToken(token);
    } catch {
      decoded = null;
    }
    if (!decoded) {
      return res.json({ success: true, data: { valid: false, message: 'Token is invalid or expired' } });
    }

    const user = await userModel.findById(decoded.sub);
    res.json({
      success: true,
      data: { valid: Boolean(user), user: user ? userModel.toPublic(user) : null },
    });
  } catch (error) {
    next(error);
  }
}
