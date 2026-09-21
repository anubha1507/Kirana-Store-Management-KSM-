-- Run after 022_payment_ceiling.sql.
-- A supplier invoice number identifies one delivery from one supplier to one
-- store, so re-entering it is almost always a mistake. NULL supplier_id (a
-- walk-in purchase) maps to the all-zero uuid so those are de-duplicated too.
BEGIN;

CREATE UNIQUE INDEX purchases_supplier_invoice_unique
  ON public.purchases (
    store_id,
    COALESCE(supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(btrim(invoice_number))
  );

COMMIT;
