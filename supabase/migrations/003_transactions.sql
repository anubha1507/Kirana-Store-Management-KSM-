-- Run after 002_catalog.sql.
BEGIN;

-- ============================================================================
-- PURCHASES
-- Ledger convention: amounts are never negative; totals are enforced.
-- ============================================================================
CREATE TABLE public.purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  supplier_id uuid,
  invoice_number text NOT NULL CHECK (length(btrim(invoice_number)) BETWEEN 1 AND 64),
  subtotal public.money_amount NOT NULL DEFAULT 0,
  tax_amount public.money_amount NOT NULL DEFAULT 0,
  discount_amount public.money_amount NOT NULL DEFAULT 0,
  total_amount public.money_amount NOT NULL,
  payment_status public.payment_status NOT NULL DEFAULT 'paid',
  notes text,
  purchased_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id),
  CONSTRAINT purchases_total_check
    CHECK (total_amount = subtotal + tax_amount - discount_amount),
  CONSTRAINT purchases_supplier_same_store_fk
    FOREIGN KEY (supplier_id, store_id) REFERENCES public.suppliers (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.purchase_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  purchase_id uuid NOT NULL,
  product_id uuid NOT NULL,
  quantity public.positive_quantity NOT NULL,
  unit_cost public.money_amount NOT NULL,
  total_cost public.money_amount NOT NULL,
  CONSTRAINT purchase_items_total_check CHECK (total_cost = round(quantity * unit_cost, 2)),
  CONSTRAINT purchase_items_purchase_same_store_fk
    FOREIGN KEY (purchase_id, store_id) REFERENCES public.purchases (id, store_id) ON DELETE CASCADE,
  CONSTRAINT purchase_items_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

-- ============================================================================
-- SALES
-- ============================================================================
CREATE TABLE public.sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  customer_id uuid,
  invoice_number text NOT NULL CHECK (length(btrim(invoice_number)) BETWEEN 1 AND 64),
  subtotal public.money_amount NOT NULL DEFAULT 0,
  discount_amount public.money_amount NOT NULL DEFAULT 0,
  tax_amount public.money_amount NOT NULL DEFAULT 0,
  total_amount public.money_amount NOT NULL,
  payment_method public.payment_method NOT NULL,
  payment_status public.payment_status NOT NULL DEFAULT 'paid',
  notes text,
  cancelled_at timestamptz,
  cancelled_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  cancel_reason text,
  sold_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id),
  UNIQUE (store_id, invoice_number),
  CONSTRAINT sales_total_check CHECK (total_amount = subtotal - discount_amount + tax_amount),
  -- A sale is either active or cancelled; cancellation always carries a reason.
  CONSTRAINT sales_cancellation_check CHECK (
    (cancelled_at IS NULL AND cancel_reason IS NULL) OR
    (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL
      AND length(btrim(cancel_reason)) BETWEEN 3 AND 500)
  ),
  CONSTRAINT sales_customer_same_store_fk
    FOREIGN KEY (customer_id, store_id) REFERENCES public.customers (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.sale_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  sale_id uuid NOT NULL,
  product_id uuid NOT NULL,
  product_name text NOT NULL,
  quantity public.positive_quantity NOT NULL,
  unit_price public.money_amount NOT NULL,
  discount_amount public.money_amount NOT NULL DEFAULT 0,
  tax_amount public.money_amount NOT NULL DEFAULT 0,
  total_price public.money_amount NOT NULL,
  CONSTRAINT sale_items_total_check
    CHECK (total_price = round(quantity * unit_price - discount_amount + tax_amount, 2)),
  CONSTRAINT sale_items_sale_same_store_fk
    FOREIGN KEY (sale_id, store_id) REFERENCES public.sales (id, store_id) ON DELETE CASCADE,
  CONSTRAINT sale_items_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

-- ============================================================================
-- PAYMENTS (supports split payment across methods)
-- ============================================================================
CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  sale_id uuid NOT NULL,
  amount public.positive_money NOT NULL,
  payment_method public.payment_method NOT NULL,
  transaction_reference text,
  paid_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_sale_same_store_fk
    FOREIGN KEY (sale_id, store_id) REFERENCES public.sales (id, store_id) ON DELETE CASCADE,
  -- 'credit' records an unpaid balance, so it may not be used as a payment.
  CONSTRAINT payments_method_check CHECK (payment_method <> 'credit')
);

-- ============================================================================
-- STOCK MOVEMENTS (immutable, signed quantity convention)
-- quantity > 0 = stock added, quantity < 0 = stock removed.
-- previous_quantity + quantity = new_quantity is always enforced.
-- ============================================================================
CREATE TABLE public.stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  movement_type public.stock_movement_type NOT NULL,
  quantity numeric(12,3) NOT NULL
    CHECK (quantity <> 0 AND quantity > -1000000000 AND quantity < 1000000000),
  previous_quantity numeric(12,3) NOT NULL,
  new_quantity numeric(12,3) NOT NULL,
  reference_id uuid,
  reference_type text,
  notes text,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_movements_balance_check
    CHECK (round(previous_quantity + quantity, 3) = new_quantity),
  CONSTRAINT stock_movements_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.inventory_adjustments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  movement_type public.stock_movement_type NOT NULL
    CHECK (movement_type IN ('damage', 'expiry', 'manual_adjustment')),
  quantity numeric(12,3) NOT NULL CHECK (quantity <> 0),
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  stock_movement_id uuid NOT NULL REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_adjustments_product_same_store_fk
    FOREIGN KEY (product_id, store_id) REFERENCES public.products (id, store_id) ON DELETE RESTRICT
);

-- ============================================================================
-- CUSTOMER LEDGER
-- amount > 0 increases the outstanding balance owed by the customer.
-- amount < 0 decreases it (payments, refunds to the customer, write-offs).
-- customers.current_balance is always kept equal to SUM(amount) per customer.
-- ============================================================================
CREATE TABLE public.customer_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL,
  transaction_type public.customer_transaction_type NOT NULL,
  amount numeric(12,2) NOT NULL
    CHECK (amount <> 0 AND amount > -10000000000 AND amount < 10000000000),
  reference_id uuid,
  reference_type text,
  description text,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_transactions_customer_same_store_fk
    FOREIGN KEY (customer_id, store_id) REFERENCES public.customers (id, store_id) ON DELETE RESTRICT,
  -- credit_sale increases what the customer owes.
  -- payment and refund reduce it (a refund here is a credit note against prior
  -- credit purchases: value flowing back to the customer).
  -- adjustment may use either sign and is reserved for supervised corrections.
  CONSTRAINT customer_transactions_sign_check CHECK (
    (transaction_type = 'credit_sale' AND amount > 0) OR
    (transaction_type IN ('payment', 'refund') AND amount < 0) OR
    (transaction_type = 'adjustment')
  )
);

CREATE TABLE public.credit_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL,
  customer_transaction_id uuid NOT NULL
    REFERENCES public.customer_transactions(id) ON DELETE RESTRICT,
  amount public.positive_money NOT NULL,
  payment_method public.payment_method NOT NULL CHECK (payment_method <> 'credit'),
  notes text,
  paid_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT credit_payments_customer_same_store_fk
    FOREIGN KEY (customer_id, store_id) REFERENCES public.customers (id, store_id) ON DELETE RESTRICT
);

ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_payments ENABLE ROW LEVEL SECURITY;
COMMIT;