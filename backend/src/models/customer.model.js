import { db, withAuth } from '../config/db.js';

const SELECT_COLS = `
  c.id, c.name, c.phone, c.email, c.address,
  c.credit_limit, c.current_balance, c.is_active, c.created_at, c.updated_at`;

export async function list({ search, active } = {}) {
  let sql = `SELECT ${SELECT_COLS} FROM public.customers c WHERE c.deleted_at IS NULL`;
  const params = [];
  let paramIndex = 1;

  if (search) {
    sql += ` AND (c.name ILIKE $${paramIndex} OR c.phone ILIKE $${paramIndex} OR c.email ILIKE $${paramIndex})`;
    params.push(`%${search}%`);
    paramIndex++;
  }

  if (active !== undefined) {
    sql += ` AND c.is_active = $${paramIndex++}`;
    params.push(active === 'true');
  }

  sql += ` ORDER BY c.name ASC LIMIT 100`;

  const { rows } = await db.query(sql, params);
  return rows;
}

export async function lookup(q, limit = 50) {
  const { rows } = await db.query(
    `SELECT
       c.id, c.name, c.phone, c.email, c.current_balance, c.credit_limit
     FROM public.customers c
     WHERE c.deleted_at IS NULL
       AND c.is_active = true
       AND (c.name ILIKE $1 OR c.phone ILIKE $1 OR c.email ILIKE $1)
     ORDER BY
      CASE WHEN c.name ILIKE $1 THEN 0 ELSE 1 END,
      c.name
     LIMIT $2`,
    [`%${q}%`, parseInt(limit, 10)]
  );
  return rows;
}

export async function getById(id) {
  const { rows } = await db.query(
    `SELECT ${SELECT_COLS} FROM public.customers c
     WHERE c.id = $1 AND c.deleted_at IS NULL`,
    [id]
  );
  return rows[0] || null;
}

export async function findPhoneConflict(storeId, phone) {
  if (!phone) return null;
  const { rows } = await db.query(
    `SELECT id FROM public.customers
     WHERE store_id = $1 AND deleted_at IS NULL AND phone = $2`,
    [storeId, phone]
  );
  return rows[0] || null;
}

export async function create(storeId, { name, phone, email, address, credit_limit }) {
  const { rows } = await db.query(
    `INSERT INTO public.customers
     (store_id, name, phone, email, address, credit_limit, current_balance, is_active)
     VALUES ($1, $2, $3, $4, $5, $6, 0, true)
     RETURNING *`,
    [storeId, name, phone || null, email || null, address || null, credit_limit || 0]
  );
  return rows[0];
}

export async function update(id, storeId, updates) {
  const allowedFields = ['name', 'phone', 'email', 'address', 'credit_limit', 'is_active'];

  const setClauses = [];
  const values = [];
  let paramIndex = 1;

  for (const field of allowedFields) {
    if (updates[field] !== undefined) {
      setClauses.push(`${field} = $${paramIndex++}`);
      values.push(updates[field]);
    }
  }

  if (setClauses.length === 0) return { error: 'no_fields' };

  setClauses.push(`updated_at = NOW()`);
  values.push(id, storeId);

  const { rows } = await db.query(
    `UPDATE public.customers
     SET ${setClauses.join(', ')}
     WHERE id = $${paramIndex} AND store_id = $${paramIndex + 1} AND deleted_at IS NULL
     RETURNING *`,
    values
  );
  return rows[0] || null;
}

export async function softDelete(id, storeId) {
  const { rows } = await db.query(
    `UPDATE public.customers
     SET is_active = false, deleted_at = NOW(), updated_at = NOW()
     WHERE id = $1 AND store_id = $2 AND deleted_at IS NULL
     RETURNING id, name, is_active, deleted_at`,
    [id, storeId]
  );
  return rows[0] || null;
}

// Settles udhaar via the record_customer_payment RPC. Runs inside withAuth so
// auth.uid()/private.assert_store_role see the caller's JWT claims.
export async function recordPayment({ user, storeId, customerId, amount, paymentMethod, notes, requestId }) {
  const { rows } = await withAuth(user, (client) =>
    client.query(
      `SELECT public.record_customer_payment($1, $2, $3, $4, $5, $6) AS result`,
      [storeId, customerId, amount, paymentMethod || 'cash', notes || null, requestId || null]
    )
  );
  return rows[0]?.result ?? null;
}
