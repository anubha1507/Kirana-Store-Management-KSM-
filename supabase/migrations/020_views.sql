-- Run after 019_indexes.sql.
-- Reporting views. Every view is created WITH (security_invoker = true) so the
-- caller's RLS policies are applied to the underlying tables: a view can never
-- be used to read another store's data, and cashiers see only what their role
-- allows. Cancelled sales are excluded from revenue figures.
BEGIN;

-- Daily takings split by settlement method.
CREATE OR REPLACE VIEW public.daily_sales_summary
WITH (security_invoker = true) AS
SELECT s.store_id,
       (s.sold_at AT TIME ZONE COALESCE(st.timezone, 'Asia/Kolkata'))::date AS sale_date,
       COUNT(*) AS transaction_count,
       SUM(s.total_amount) AS total_sales,
       SUM(s.discount_amount) AS total_discount,
       SUM(s.tax_amount) AS total_tax,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'cash'), 0) AS cash_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'upi'), 0) AS upi_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'card'), 0) AS card_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'credit'), 0) AS credit_sales,
       COALESCE(SUM(s.total_amount) FILTER (WHERE s.payment_method = 'mixed'), 0) AS mixed_sales
  FROM public.sales s
  LEFT JOIN public.stores st ON st.id = s.store_id
 WHERE s.cancelled_at IS NULL
 GROUP BY s.store_id,
          (s.sold_at AT TIME ZONE COALESCE(st.timezone, 'Asia/Kolkata'))::date;

-- Which products actually sell, and how much they earn.
CREATE OR REPLACE VIEW public.product_sales_summary
WITH (security_invoker = true) AS
SELECT si.store_id,
       si.product_id,
       max(si.product_name) AS product_name,
       SUM(si.quantity) AS total_quantity_sold,
       SUM(si.total_price) AS total_revenue,
       COUNT(DISTINCT si.sale_id) AS sale_count,
       max(s.sold_at) AS last_sold_at
  FROM public.sale_items si
  JOIN public.sales s ON s.id = si.sale_id
 WHERE s.cancelled_at IS NULL
 GROUP BY si.store_id, si.product_id;

-- Reorder worklist: active products at or below their threshold.
CREATE OR REPLACE VIEW public.low_stock_products
WITH (security_invoker = true) AS
SELECT p.store_id,
       p.id AS product_id,
       p.name AS product_name,
       p.sku,
       p.stock_quantity,
       p.low_stock_threshold,
       p.unit,
       c.name AS category_name,
       (p.low_stock_threshold - p.stock_quantity) AS shortfall
  FROM public.products p
  LEFT JOIN public.categories c ON c.id = p.category_id
 WHERE p.deleted_at IS NULL
   AND p.is_active
   AND p.stock_quantity <= p.low_stock_threshold;

-- Udhaar collection worklist.
CREATE OR REPLACE VIEW public.customer_outstanding_balances
WITH (security_invoker = true) AS
SELECT c.store_id,
       c.id AS customer_id,
       c.name AS customer_name,
       c.phone,
       c.credit_limit,
       c.current_balance,
       CASE WHEN c.credit_limit > 0
            THEN GREATEST(c.credit_limit - c.current_balance, 0)
            ELSE NULL END AS credit_available,
       (SELECT max(t.created_at) FROM public.customer_transactions t
         WHERE t.customer_id = c.id) AS last_transaction_at
  FROM public.customers c
 WHERE c.deleted_at IS NULL
   AND c.is_active
   AND c.current_balance > 0;

-- Stock on hand valued at the current weighted-average cost.
CREATE OR REPLACE VIEW public.inventory_valuation
WITH (security_invoker = true) AS
SELECT p.store_id,
       SUM(p.stock_quantity * p.cost_price) AS stock_value_at_cost,
       SUM(p.stock_quantity * p.selling_price) AS stock_value_at_retail,
       COUNT(*) FILTER (WHERE p.stock_quantity <= p.low_stock_threshold) AS low_stock_count
  FROM public.products p
 WHERE p.deleted_at IS NULL AND p.is_active
 GROUP BY p.store_id;

GRANT SELECT ON public.daily_sales_summary TO authenticated;
GRANT SELECT ON public.product_sales_summary TO authenticated;
GRANT SELECT ON public.low_stock_products TO authenticated;
GRANT SELECT ON public.customer_outstanding_balances TO authenticated;
GRANT SELECT ON public.inventory_valuation TO authenticated;

COMMIT;
