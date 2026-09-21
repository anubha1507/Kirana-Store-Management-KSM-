-- Run after 006_triggers.sql.
-- ============================================================================
-- RPC: store and membership administration
-- Every function is SECURITY DEFINER with a pinned search_path and derives the
-- caller identity from auth.uid() rather than trusting an argument. EXECUTE is
-- revoked from PUBLIC/anon and granted to authenticated.
-- ============================================================================
BEGIN;

-- Creates a store owned by the caller. The bootstrap_store trigger then adds
-- the owner membership and the default settings row, so a store can never
-- exist without an owner and configuration.
CREATE OR REPLACE FUNCTION public.create_store(
  p_name text,
  p_phone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_pincode text DEFAULT NULL,
  p_gst_number text DEFAULT NULL,
  p_timezone text DEFAULT 'Asia/Kolkata'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid;
  v_store public.stores;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'store name is required' USING ERRCODE = '22023';
  END IF;

  -- Validate the timezone explicitly: an invalid zone would otherwise fail
  -- later, inside invoice numbering, at the worst possible moment.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names t WHERE t.name = p_timezone) THEN
    RAISE EXCEPTION 'unknown timezone %', p_timezone USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.stores
    (name, owner_id, phone, email, address, city, state, pincode, gst_number, timezone)
  VALUES
    (btrim(p_name), v_user_id, p_phone, p_email, p_address, p_city, p_state,
     p_pincode, p_gst_number, p_timezone)
  RETURNING * INTO v_store;

  RETURN to_jsonb(v_store);
END;
$$;

-- Owner-facing settings update. Named parameters keep the call self-documenting
-- and stop a client from clearing a setting it did not intend to touch.
CREATE OR REPLACE FUNCTION public.update_store_settings(
  p_store_id uuid,
  p_invoice_prefix text DEFAULT NULL,
  p_enable_gst boolean DEFAULT NULL,
  p_default_tax_rate numeric DEFAULT NULL,
  p_allow_negative_stock boolean DEFAULT NULL,
  p_cashier_can_record_payments boolean DEFAULT NULL,
  p_low_stock_default_threshold numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_settings public.store_settings;
BEGIN
  PERFORM private.assert_store_role(p_store_id, 'owner');

  UPDATE public.store_settings
     SET invoice_prefix = COALESCE(p_invoice_prefix, invoice_prefix),
         enable_gst = COALESCE(p_enable_gst, enable_gst),
         default_tax_rate = COALESCE(p_default_tax_rate, default_tax_rate),
         allow_negative_stock = COALESCE(p_allow_negative_stock, allow_negative_stock),
         cashier_can_record_payments =
           COALESCE(p_cashier_can_record_payments, cashier_can_record_payments),
         low_stock_default_threshold =
           COALESCE(p_low_stock_default_threshold, low_stock_default_threshold)
   WHERE store_id = p_store_id
  RETURNING * INTO v_settings;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'settings not found for store %', p_store_id USING ERRCODE = '22023';
  END IF;

  RETURN to_jsonb(v_settings);
END;
$$;

-- MEMBERS_ANCHOR

REVOKE ALL ON FUNCTION public.update_store_settings(uuid, text, boolean, numeric, boolean, boolean, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_store_settings(uuid, text, boolean, numeric, boolean, boolean, numeric)
  TO authenticated;

REVOKE ALL ON FUNCTION public.create_store(text, text, text, text, text, text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_store(text, text, text, text, text, text, text, text, text)
  TO authenticated;

COMMIT;
