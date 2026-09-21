-- Run migrations in numeric order as postgres, on a fresh Supabase project.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TYPE public.user_role AS ENUM ('owner', 'manager', 'cashier');
CREATE TYPE public.payment_method AS ENUM ('cash', 'upi', 'credit', 'card', 'mixed');
CREATE TYPE public.payment_status AS ENUM ('paid', 'pending', 'partial');
CREATE TYPE public.stock_movement_type AS ENUM
  ('purchase', 'sale', 'sale_return', 'purchase_return', 'damage', 'expiry', 'manual_adjustment');
CREATE TYPE public.customer_transaction_type AS ENUM ('credit_sale', 'payment', 'adjustment', 'refund');

-- Domain bounds reject NaN and infinities as well as overflow/negative values.
CREATE DOMAIN public.money_amount AS numeric(12,2)
  CHECK (VALUE >= 0 AND VALUE < 10000000000);
CREATE DOMAIN public.positive_money AS numeric(12,2)
  CHECK (VALUE > 0 AND VALUE < 10000000000);
CREATE DOMAIN public.positive_quantity AS numeric(12,3)
  CHECK (VALUE > 0 AND VALUE < 1000000000);

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text,
  phone text,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.user_roles (
  role public.user_role PRIMARY KEY,
  description text NOT NULL
);
INSERT INTO public.user_roles VALUES
  ('owner', 'Store administration and all operational permissions'),
  ('manager', 'Catalog, purchasing, inventory, customers, sales and reports'),
  ('cashier', 'Restricted lookup, checkout, sales history and permitted payments');

CREATE TABLE public.stores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  phone text, email text, address text, city text, state text,
  pincode text CHECK (pincode IS NULL OR pincode ~ '^[0-9]{6}$'),
  gst_number text CHECK (gst_number IS NULL OR gst_number ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  logo_url text,
  currency text NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
  timezone text NOT NULL DEFAULT 'Asia/Kolkata',
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.store_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.user_role NOT NULL REFERENCES public.user_roles(role),
  is_active boolean NOT NULL DEFAULT true,
  joined_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, user_id)
);
CREATE TABLE public.store_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL UNIQUE REFERENCES public.stores(id) ON DELETE CASCADE,
  invoice_prefix text NOT NULL DEFAULT 'INV' CHECK (invoice_prefix ~ '^[A-Z0-9]{1,12}$'),
  enable_gst boolean NOT NULL DEFAULT false,
  default_tax_rate numeric(5,2) NOT NULL DEFAULT 0 CHECK (default_tax_rate BETWEEN 0 AND 100),
  allow_negative_stock boolean NOT NULL DEFAULT false,
  cashier_can_record_payments boolean NOT NULL DEFAULT false,
  low_stock_default_threshold numeric(12,3) NOT NULL DEFAULT 5
    CHECK (low_stock_default_threshold >= 0 AND low_stock_default_threshold < 1000000000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Concurrency-safe document numbering. One row per store/document type/calendar
-- year. next_document_number() upserts this row with a row lock, so two
-- simultaneous checkouts can never share a number.
CREATE TABLE public.invoice_counters (
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  doc_type text NOT NULL CHECK (doc_type IN ('sale', 'purchase')),
  year integer NOT NULL CHECK (year BETWEEN 2000 AND 9999),
  last_value bigint NOT NULL CHECK (last_value > 0),
  PRIMARY KEY (store_id, doc_type, year)
);
CREATE TABLE public.rpc_requests (
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL,
  operation text NOT NULL,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  payload jsonb NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, request_id)
);
CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpc_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
COMMIT;