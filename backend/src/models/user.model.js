import { db } from '../config/db.js';

const COLS = `id, email, full_name, role, avatar_url, store_id, is_active, created_at, updated_at`;

export async function findByEmail(email) {
  const { rows } = await db.query(
    `SELECT * FROM public.backend_users WHERE lower(email) = lower($1)`,
    [email]
  );
  return rows[0] || null;
}

export async function findById(id) {
  const { rows } = await db.query(
    `SELECT ${COLS} FROM public.backend_users WHERE id = $1`,
    [id]
  );
  return rows[0] || null;
}

// Inserts the account and provisions its store in one transaction (see
// auth.controller.signup — the caller runs this inside withAuth so the
// create_store RPC sees the same auth.uid() claims).
export async function insert(client, { id, email, fullName, passwordHash, role }) {
  const { rows } = await client.query(
    `INSERT INTO public.backend_users (id, email, full_name, password_hash, role)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING ${COLS}`,
    [id, email, fullName, passwordHash, role]
  );
  return rows[0];
}

export async function setStore(client, id, storeId) {
  const { rows } = await client.query(
    `UPDATE public.backend_users SET store_id = $1 WHERE id = $2 RETURNING ${COLS}`,
    [storeId, id]
  );
  return rows[0] || null;
}

export async function list() {
  const { rows } = await db.query(
    `SELECT ${COLS} FROM public.backend_users ORDER BY created_at DESC`
  );
  return rows;
}

export async function update(id, { fullName, role, avatarUrl }) {
  const { rows } = await db.query(
    `UPDATE public.backend_users
     SET full_name = COALESCE($1, full_name),
         role = COALESCE($2, role),
         avatar_url = COALESCE($3, avatar_url),
         updated_at = NOW()
     WHERE id = $4
     RETURNING ${COLS}`,
    [fullName, role, avatarUrl, id]
  );
  return rows[0] || null;
}

export async function deactivate(id) {
  const { rows } = await db.query(
    `UPDATE public.backend_users
     SET is_active = false, updated_at = NOW()
     WHERE id = $1
     RETURNING ${COLS}`,
    [id]
  );
  return rows[0] || null;
}

export async function touchLastLogin(id) {
  await db.query(
    `UPDATE public.backend_users SET last_login_at = NOW() WHERE id = $1`,
    [id]
  );
}

// API-facing shape (camelCase) shared by every auth response.
export function toPublic(row) {
  if (!row) return null;
  return {
    id: row.id,
    email: row.email,
    fullName: row.full_name,
    role: row.role,
    avatarUrl: row.avatar_url,
    storeId: row.store_id ?? null,
  };
}
