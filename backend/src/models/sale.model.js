import { db, withAuth } from '../config/db.js';

const SALE_COLS = `
  s.id, s.invoice_number, s.subtotal, s.discount_amount, s.tax_amount,
  s.total_amount, s.payment_method, s.payment_status, s.notes,
  s.sold_at, s.created_by, s.created_at,
  c.name as customer_name, c.phone as customer_phone`;

const SALE_FROM = `
  FROM public.sales s
  LEFT JOIN public.customers c ON c.id = s.customer_id AND c.deleted_at IS NULL
  WHERE s.cancelled_at IS NULL`;

export async function list({ storeId, startDate, endDate, customerId, paymentMethod } = {}) {
  let sql = `SELECT ${SALE_COLS} ${SALE_FROM}`;
  const params = [];
  let paramIndex = 1;

  if (storeId) {
    sql += ` AND s.store_id = $${paramIndex++}`;
    params.push(storeId);
  }
  if (startDate) {
    sql += ` AND s.sold_at >= $${paramIndex++}`;
    params.push(startDate);
  }
  if (endDate) {
    sql += ` AND s.sold_at <= $${paramIndex++}`;
    params.push(endDate);
  }
  if (customerId) {
    sql += ` AND s.customer_id = $${paramIndex++}`;
    params.push(customerId);
  }
  if (paymentMethod) {
    sql += ` AND s.payment_method = $${paramIndex++}`;
    params.push(paymentMethod);
  }

  sql += ` ORDER BY s.sold_at DESC LIMIT 100`;

  const { rows } = await db.query(sql, params);
  return rows;
}

export async function getById(id, storeId) {
  const { rows } = await db.query(
    `SELECT
       ${SALE_COLS.replace('c.name as customer_name', 'c.id as customer_id, c.name as customer_name')}
     ${SALE_FROM}
     AND s.id = $1 ${storeId ? 'AND s.store_id = $2' : ''}`,
    storeId ? [id, storeId] : [id]
  );
  return rows[0] || null;
}

export async function items(saleId) {
  const { rows } = await db.query(
    `SELECT
       si.id, si.product_id, si.quantity, si.unit_price, si.total_price,
       p.name as product_name, p.unit as product_unit
     FROM public.sale_items si
     JOIN public.products p ON p.id = si.product_id
     WHERE si.sale_id = $1`,
    [saleId]
  );
  return rows;
}

// Checkout through the create_sale RPC (server-side pricing, stock guard,
// payment ceiling, credit-limit guard, idempotency) inside a transaction that
// carries the caller's JWT claims.
export async function createSale({ user, storeId, items: cartItems, paymentMethod, customerId, discountAmount, taxAmount, notes, requestId }) {
  const { rows } = await withAuth(user, (client) =>
    client.query(
      `SELECT * FROM public.create_sale(
         $1,  -- p_store_id
         $2,  -- p_items (jsonb)
         $3,  -- p_payment_method
         $4,  -- p_customer_id
         $5,  -- p_discount_amount
         $6,  -- p_tax_amount
         $7,  -- p_notes
         null, -- p_payments
         $8   -- p_request_id
       )`,
      [
        storeId,
        JSON.stringify(cartItems.map((item) => ({
          product_id: item.product_id,
          quantity: item.quantity,
          discount_amount: item.discount || item.discount_amount || 0,
        }))),
        paymentMethod,
        customerId || null,
        discountAmount || 0,
        taxAmount || 0,
        notes || null,
        requestId || null,
      ]
    )
  );
  return rows[0] || null;
}

export async function cancelSale({ user, id, reason, userId }) {
  const { rows } = await withAuth(user, (client) =>
    client.query(`SELECT * FROM public.cancel_sale($1, $2, $3)`, [id, reason, userId])
  );
  return rows[0] || null;
}
