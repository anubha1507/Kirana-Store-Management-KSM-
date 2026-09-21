-- Run after 021_seed_data.sql.
-- Cross-row rule a CHECK constraint cannot express: payments against one sale
-- may never exceed that sale's total.
BEGIN;

CREATE OR REPLACE FUNCTION private.guard_payment_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_total numeric(12,2);
  v_cancelled timestamptz;
  v_paid numeric(12,2);
BEGIN
  -- Lock the sale row so two concurrent payments on one bill serialise and
  -- cannot each pass the ceiling check independently.
  SELECT total_amount, cancelled_at
    INTO v_total, v_cancelled
    FROM public.sales
   WHERE id = NEW.sale_id
   FOR UPDATE;

  IF v_total IS NULL THEN
    RAISE EXCEPTION 'sale % does not exist', NEW.sale_id USING ERRCODE = '23503';
  END IF;

  IF v_cancelled IS NOT NULL THEN
    RAISE EXCEPTION 'cannot take a payment for a cancelled sale' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.payments
   WHERE sale_id = NEW.sale_id;

  IF v_paid + NEW.amount > v_total THEN
    RAISE EXCEPTION 'payments for sale % would total %, exceeding the sale total %',
      NEW.sale_id, v_paid + NEW.amount, v_total
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER guard_payment_total BEFORE INSERT ON public.payments
  FOR EACH ROW EXECUTE FUNCTION private.guard_payment_total();

REVOKE ALL ON FUNCTION private.guard_payment_total() FROM PUBLIC, anon, authenticated;

COMMIT;
