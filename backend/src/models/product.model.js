import { db } from '../config/db.js';

const SELECT_COLS = `
  p.id, p.sku, p.name, p.description, p.category_id,
  COALESCE(c.name, '') as category_name,
  p.cost_price, p.selling_price, p.stock_quantity, p.unit,
  p.low_stock_threshold, p.is_active, p.created_at, p.updated_at,
  p.deleted_at`;

const FROM_CLAUSE = `
  FROM public.products p
  LEFT JOIN public.categories c ON c.id = p.category_id AND c.deleted_at IS NULL`;

// Builds the shared list query with optional filters.
export function buildProductQuery(filters = {}) {
  let sql = `SELECT ${SELECT_COLS} ${FROM_CLAUSE} WHERE 1=1`;
  const params = [];
  let paramIndex = 1;

  if (filters.storeId) {
    sql += ` AND p.store_id = $${paramIndex++}`;
    params.push(filters.storeId);
  }

  if (filters.search) {
    sql += ` AND (p.name ILIKE $${paramIndex} OR p.sku ILIKE $${paramIndex} OR p.barcode ILIKE $${paramIndex})`;
    params.push(`%${filters.search}%`);
    paramIndex++;
  }

  if (filters.categoryId) {
    sql += ` AND p.category_id = $${paramIndex++}`;
    params.push(filters.categoryId);
  }

  if (filters.isActive !== undefined) {
    sql += ` AND p.is_active = $${paramIndex++}`;
    params.push(filters.isActive);
  }

  if (filters.lowStock) {
    sql += ` AND p.stock_quantity <= p.low_stock_threshold AND p.stock_quantity > 0`;
  }

  sql += ` ORDER BY p.name ASC`;
  return { sql, params };
}

export async function list(filters) {
  const { sql, params } = buildProductQuery(filters);
  const { rows } = await db.query(sql, params);
  return rows;
}

export async function lookup(q, limit = 50) {
  const { rows } = await db.query(
    `SELECT
       p.id, p.name, p.sku, p.barcode, p.selling_price,
       p.stock_quantity, p.unit, p.is_active,
       COALESCE(c.name, '') as category_name
     ${FROM_CLAUSE}
     WHERE p.deleted_at IS NULL
       AND p.is_active = true
       AND (p.name ILIKE $1 OR p.sku ILIKE $1 OR p.barcode ILIKE $1)
     ORDER BY p.name
     LIMIT $2`,
    [`%${q}%`, parseInt(limit, 10)]
  );
  return rows;
}

export async function getById(id) {
  const { rows } = await db.query(
    `SELECT ${SELECT_COLS} ${FROM_CLAUSE} WHERE p.id = $1`,
    [id]
  );
  return rows[0] || null;
}

export async function findConflict(storeId, sku, barcode) {
  if (!sku && !barcode) return null;
  const { rows } = await db.query(
    `SELECT id FROM public.products
     WHERE store_id = $1 AND deleted_at IS NULL
       AND (sku = $2 OR barcode = $3)`,
    [storeId, sku || null, barcode || null]
  );
  return rows[0] || null;
}

export async function create(storeId, fields) {
  const {
    name, selling_price, stock_quantity, unit, sku, barcode,
    category_id, cost_price, low_stock_threshold, description,
  } = fields;
  const { rows } = await db.query(
    `INSERT INTO public.products
     (store_id, name, sku, barcode, description, cost_price, selling_price,
      stock_quantity, unit, low_stock_threshold, is_active, category_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
     RETURNING *`,
    [
      storeId, name, sku || null, barcode || null, description || null,
      cost_price || selling_price * 0.8, selling_price, stock_quantity,
      unit || 'piece', low_stock_threshold || 5, true, category_id || null,
    ]
  );
  return rows[0];
}

export async function update(id, storeId, updates) {
  const allowedFields = [
    'name', 'sku', 'barcode', 'description', 'category_id',
    'cost_price', 'selling_price', 'stock_quantity', 'unit',
    'low_stock_threshold', 'is_active',
  ];

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
    `UPDATE public.products
     SET ${setClauses.join(', ')}
     WHERE id = $${paramIndex} AND store_id = $${paramIndex + 1}
     RETURNING *`,
    values
  );
  return rows[0] || null;
}

export async function softDelete(id, storeId) {
  const { rows } = await db.query(
    `UPDATE public.products
     SET is_active = false, deleted_at = NOW(), updated_at = NOW()
     WHERE id = $1 AND store_id = $2 AND deleted_at IS NULL
     RETURNING id, name, is_active, deleted_at`,
    [id, storeId]
  );
  return rows[0] || null;
}
