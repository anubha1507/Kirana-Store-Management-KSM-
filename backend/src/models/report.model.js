import { db } from '../config/db.js';

// Dashboard summary: today's takings, all-time totals and store vitals.
export async function summary(storeId) {
  const { rows: todayRows } = await db.query(
    `SELECT
       COUNT(*) as total_bills,
       COALESCE(SUM(total_amount), 0) as total_sales,
       COALESCE(SUM(discount_amount), 0) as total_discount,
       COALESCE(SUM(tax_amount), 0) as total_tax
     FROM public.sales
     WHERE store_id = $1
       AND cancelled_at IS NULL
       AND sold_at >= CURRENT_DATE
       AND sold_at < CURRENT_DATE + INTERVAL '1 day'`,
    [storeId]
  );

  const { rows: allTimeRows } = await db.query(
    `SELECT COUNT(*) as total_bills, COALESCE(SUM(total_amount), 0) as total_sales
     FROM public.sales
     WHERE store_id = $1 AND cancelled_at IS NULL`,
    [storeId]
  );

  const { rows: productRows } = await db.query(
    `SELECT
       COUNT(*) FILTER (WHERE deleted_at IS NULL AND is_active) as active_products,
       COUNT(*) FILTER (WHERE deleted_at IS NULL AND is_active
                          AND stock_quantity <= low_stock_threshold) as low_stock_count
     FROM public.products
     WHERE store_id = $1`,
    [storeId]
  );

  const { rows: customerRows } = await db.query(
    `SELECT COUNT(*) as customers, COALESCE(SUM(current_balance), 0) as udhaar_total
     FROM public.customers
     WHERE store_id = $1 AND deleted_at IS NULL`,
    [storeId]
  );

  const { rows: movementRows } = await db.query(
    `SELECT COUNT(*) as movements FROM public.stock_movements WHERE store_id = $1`,
    [storeId]
  );

  return {
    today: {
      total_bills: parseInt(todayRows[0].total_bills, 10),
      total_sales: parseFloat(todayRows[0].total_sales),
      total_discount: parseFloat(todayRows[0].total_discount),
      total_tax: parseFloat(todayRows[0].total_tax),
    },
    all_time: {
      total_bills: parseInt(allTimeRows[0].total_bills, 10),
      total_sales: parseFloat(allTimeRows[0].total_sales),
    },
    store: {
      active_products: parseInt(productRows[0].active_products, 10),
      low_stock_count: parseInt(productRows[0].low_stock_count, 10),
      customers: parseInt(customerRows[0].customers, 10),
      udhaar_total: parseFloat(customerRows[0].udhaar_total),
      movements: parseInt(movementRows[0].movements, 10),
    },
  };
}

// Which products sell, and how much they earn (020_views.sql).
export async function productSales(storeId, limit = 100) {
  const { rows } = await db.query(
    `SELECT product_id, product_name, total_quantity_sold, total_revenue, sale_count, last_sold_at
     FROM public.product_sales_summary
     WHERE store_id = $1
     ORDER BY total_revenue DESC
     LIMIT $2`,
    [storeId, limit]
  );
  return rows;
}

// Recent stock ledger rows (sale/purchase/adjustment movements).
export async function movements(storeId, limit = 50) {
  const { rows } = await db.query(
    `SELECT m.id, m.product_id, p.name as product_name, m.movement_type,
            m.quantity, m.previous_quantity, m.new_quantity, m.created_at
     FROM public.stock_movements m
     JOIN public.products p ON p.id = m.product_id
     WHERE m.store_id = $1
     ORDER BY m.created_at DESC
     LIMIT $2`,
    [storeId, limit]
  );
  return rows;
}
