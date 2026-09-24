import { db, withAuth } from '../config/db.js';

const PURCHASE_COLS = `
  p.id, p.invoice_number, p.subtotal, p.tax_amount, p.discount_amount,
  p.total_amount, p.payment_status, p.notes,
  p.purchased_at, p.created_by, p.created_at,
  s.name as supplier_name, s.phone as supplier_phone`;

const PURCHASE_FROM = `
  FROM public.purchases p
  LEFT JOIN public.suppliers s ON s.id = p.supplier_id AND s.deleted_at IS NULL
  WHERE p.cancelled_at IS NULL`;

export async function list({ storeId, startDate, endDate, supplierId } = {}) {
  let sql = `SELECT ${PURCHASE_COLS} ${PURCHASE_FROM}`;
  const params = [];
  let paramIndex = 1;

  if (storeId) {
    sql += ` AND p.store_id = $${paramIndex++}`;
    params.push(storeId);
  }
  if (startDate) {
    sql += ` AND p.purchased_at >= $${paramIndex++}`;
    params.push(startDate);
  }
  if (endDate) {
    sql += ` AND p.purchased_at <= $${paramIndex++}`;
    params.push(endDate);
  }
  if (supplierId) {
    sql += ` AND p.supplier_id = $${paramIndex++}`;
    params.push(supplierId);
  }

  sql += ` ORDER BY p.purchased_at DESC LIMIT 100`;

  const { rows } = await db.query(sql, params);
  return rows;
}

export async function getById(id, storeId) {
  const { rows } = await db.query(
    `SELECT
       ${PURCHASE_COLS.replace('s.name as supplier_name', 's.id as supplier_id, s.name as supplier_name')}
     ${PURCHASE_FROM}
     AND p.id = $1 ${storeId ? 'AND p.store_id = $2' : ''}`,
    storeId ? [id, storeId] : [id]
  );
  return rows[0] || null;
}

export async function items(purchaseId) {
  const { rows } = await db.query(
    `SELECT
       pi.id, pi.product_id, pi.quantity, pi.unit_cost, pi.total_cost,
       p.name as product_name, p.unit as product_unit
     FROM public.purchase_items pi
     JOIN public.products p ON p.id = pi.product_id
     WHERE pi.purchase_id = $1`,
    [purchaseId]
  );
  return rows;
}

// Goods-in through the create_purchase RPC (stock ledger, weighted-average
// cost, invoice checks) with the caller's JWT claims attached.
export async function createPurchase({ user, storeId, items: cartItems, supplierId, invoiceNumber, paymentStatus, notes, requestId }) {
  const { rows } = await withAuth(user, (client) =>
    client.query(
      `SELECT * FROM public.create_purchase(
         $1,  -- p_store_id
         $2,  -- p_items (jsonb)
         $3,  -- p_supplier_id
         $4,  -- p_invoice_number
         $5,  -- p_payment_status
         $6,  -- p_tax_amount
         $7,  -- p_discount_amount
         $8,  -- p_notes
         $9   -- p_request_id
       )`,
      [
        storeId,
        JSON.stringify(cartItems.map((item) => ({
          product_id: item.product_id,
          quantity: item.quantity,
          unit_cost: item.unit_cost,
        }))),
        supplierId || null,
        invoiceNumber || null,
        paymentStatus || 'paid',
        0,
        0,
        notes || null,
        requestId || null,
      ]
    )
  );
  return rows[0] || null;
}

export async function cancelPurchase(id, storeId, reason) {
  const { rows } = await db.query(
    `UPDATE public.purchases
     SET cancelled_at = NOW(), cancel_reason = $1, updated_at = NOW()
     WHERE id = $2 AND store_id = $3 AND cancelled_at IS NULL
     RETURNING id, invoice_number, cancelled_at, cancel_reason`,
    [reason, id, storeId]
  );
  return rows[0] || null;
}
