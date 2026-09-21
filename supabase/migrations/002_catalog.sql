-- Run after 001_foundation.sql.
BEGIN;

CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  description text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- Referenced by products via a composite key, so a product cannot be
  -- attached to another store's category.
  UNIQUE (id, store_id)
);

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  category_id uuid,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  sku text CHECK (sku IS NULL OR (length(btrim(sku)) BETWEEN 1 AND 64 AND sku = btrim(sku))),
  barcode text CHECK (barcode IS NULL OR (length(btrim(barcode)) BETWEEN 4 AND 64 AND barcode = btrim(barcode))),
  description text,
  cost_price public.money_amount NOT NULL DEFAULT 0,
  selling_price public.money_amount NOT NULL,
  stock_quantity numeric(12,3) NOT NULL DEFAULT 0
    CHECK (stock_quantity > -1000000000 AND stock_quantity < 1000000000),
  unit text NOT NULL DEFAULT 'piece'
    CHECK (unit IN ('piece','packet','box','bag','kg','gram','liter','ml','dozen')),
  low_stock_threshold numeric(12,3) NOT NULL DEFAULT 5
    CHECK (low_stock_threshold >= 0 AND low_stock_threshold < 1000000000),
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id),
  CONSTRAINT products_category_same_store_fk
    FOREIGN KEY (category_id, store_id) REFERENCES public.categories (id, store_id) ON DELETE RESTRICT
);

CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  phone text, email text, address text,
  gst_number text CHECK (gst_number IS NULL OR gst_number ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  notes text,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id)
);

CREATE TABLE public.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  phone text, email text, address text,
  credit_limit public.money_amount NOT NULL DEFAULT 0,
  current_balance public.money_amount NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, store_id)
);

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
COMMIT;