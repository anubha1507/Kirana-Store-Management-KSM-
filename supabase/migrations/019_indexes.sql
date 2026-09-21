-- Run after 018_rpc_cancel_sale.sql.
-- Index strategy: every index below answers a specific query the application
-- actually issues. Uniqueness is enforced with partial indexes so soft-deleted
-- rows do not block reuse of a name, SKU, barcode or phone number.
BEGIN;

-- ---------------------------------------------------------------------------
-- Store-scoped uniqueness (respects soft deletion)
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX categories_store_name_unique
  ON public.categories (store_id, lower(btrim(name)))
  WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX products_store_sku_unique
  ON public.products (store_id, sku)
  WHERE sku IS NOT NULL AND deleted_at IS NULL;

CREATE UNIQUE INDEX products_store_barcode_unique
  ON public.products (store_id, barcode)
  WHERE barcode IS NOT NULL AND deleted_at IS NULL;

CREATE UNIQUE INDEX customers_store_phone_unique
  ON public.customers (store_id, phone)
  WHERE phone IS NOT NULL AND deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Tenant scoping (every tenant table is filtered by store_id)
-- ---------------------------------------------------------------------------
CREATE INDEX categories_store_idx ON public.categories (store_id) WHERE deleted_at IS NULL;
CREATE INDEX products_store_idx ON public.products (store_id) WHERE deleted_at IS NULL;
CREATE INDEX suppliers_store_idx ON public.suppliers (store_id) WHERE deleted_at IS NULL;
CREATE INDEX customers_store_idx ON public.customers (store_id) WHERE deleted_at IS NULL;
CREATE INDEX store_members_user_idx ON public.store_members (user_id) WHERE is_active;
CREATE INDEX store_members_store_idx ON public.store_members (store_id);
CREATE INDEX audit_logs_store_created_idx ON public.audit_logs (store_id, created_at DESC);
CREATE INDEX rpc_requests_created_idx ON public.rpc_requests (created_at);

-- ---------------------------------------------------------------------------
-- Product search (billing finds products by name, SKU or barcode)
-- ---------------------------------------------------------------------------
-- Trigram index serves the ILIKE '%term%' name search used by the POS.
CREATE INDEX products_name_trgm_idx
  ON public.products USING gin (name gin_trgm_ops)
  WHERE deleted_at IS NULL;

CREATE INDEX products_store_name_idx
  ON public.products (store_id, name)
  WHERE deleted_at IS NULL AND is_active;

-- Low-stock dashboard query: only rows at or below their threshold.
CREATE INDEX products_low_stock_idx
  ON public.products (store_id, stock_quantity)
  WHERE deleted_at IS NULL AND is_active;

CREATE INDEX products_category_idx ON public.products (category_id) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Sales and billing
-- ---------------------------------------------------------------------------
-- Sales history is always listed newest first within a store.
CREATE INDEX sales_store_sold_at_idx ON public.sales (store_id, sold_at DESC);
CREATE INDEX sales_customer_idx ON public.sales (store_id, customer_id, sold_at DESC)
  WHERE customer_id IS NOT NULL;
-- Daily report filters by sold_at range and payment method.
CREATE INDEX sales_store_method_sold_at_idx
  ON public.sales (store_id, payment_method, sold_at DESC);

CREATE INDEX sale_items_sale_idx ON public.sale_items (sale_id);
CREATE INDEX sale_items_product_idx ON public.sale_items (store_id, product_id);

CREATE INDEX payments_sale_idx ON public.payments (sale_id);
CREATE INDEX payments_store_paid_at_idx ON public.payments (store_id, paid_at DESC);

-- ---------------------------------------------------------------------------
-- Purchases
-- ---------------------------------------------------------------------------
CREATE INDEX purchases_store_purchased_at_idx ON public.purchases (store_id, purchased_at DESC);
CREATE INDEX purchases_supplier_idx
  ON public.purchases (store_id, supplier_id, purchased_at DESC)
  WHERE supplier_id IS NOT NULL;

CREATE INDEX purchase_items_purchase_idx ON public.purchase_items (purchase_id);
CREATE INDEX purchase_items_product_idx ON public.purchase_items (store_id, product_id);

-- ---------------------------------------------------------------------------
-- Inventory ledger and audit reconstruction
-- ---------------------------------------------------------------------------
-- "History for this product, newest first" is the main inventory query.
CREATE INDEX stock_movements_store_product_created_idx
  ON public.stock_movements (store_id, product_id, created_at DESC);
CREATE INDEX stock_movements_reference_idx
  ON public.stock_movements (reference_id)
  WHERE reference_id IS NOT NULL;

CREATE INDEX inventory_adjustments_product_idx
  ON public.inventory_adjustments (store_id, product_id, created_at DESC);
CREATE INDEX inventory_adjustments_movement_idx
  ON public.inventory_adjustments (stock_movement_id);

-- ---------------------------------------------------------------------------
-- Customer ledger
-- ---------------------------------------------------------------------------
CREATE INDEX customer_transactions_customer_created_idx
  ON public.customer_transactions (store_id, customer_id, created_at DESC);
-- Cancellation and reporting lookups by the originating document.
CREATE INDEX customer_transactions_reference_idx
  ON public.customer_transactions (reference_id)
  WHERE reference_id IS NOT NULL;

CREATE INDEX credit_payments_customer_paid_at_idx
  ON public.credit_payments (store_id, customer_id, paid_at DESC);
CREATE INDEX credit_payments_transaction_idx
  ON public.credit_payments (customer_transaction_id);

-- ---------------------------------------------------------------------------
-- Supplier and customer name search
-- ---------------------------------------------------------------------------
CREATE INDEX suppliers_name_trgm_idx
  ON public.suppliers USING gin (name gin_trgm_ops)
  WHERE deleted_at IS NULL;
CREATE INDEX customers_name_trgm_idx
  ON public.customers USING gin (name gin_trgm_ops)
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Foreign keys without a covering index
-- ---------------------------------------------------------------------------
CREATE INDEX purchases_created_by_idx ON public.purchases (created_by);
CREATE INDEX sales_created_by_idx ON public.sales (created_by);

COMMIT;
