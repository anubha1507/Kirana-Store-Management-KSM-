-- Run after 005_trigger_functions.sql.
-- ============================================================================
-- TRIGGER WIRING
-- Ordering notes:
--   * BEFORE triggers run alphabetically, so guard_* triggers are named to run
--     before any trigger that would otherwise mutate the row.
--   * AFTER triggers on the same table also run alphabetically; the audit
--     trigger is named to run last so it observes the final row image.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.store_settings
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.categories
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Store bootstrap and ownership protection
-- ---------------------------------------------------------------------------
CREATE TRIGGER bootstrap_store AFTER INSERT ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.bootstrap_store();

CREATE TRIGGER guard_store_update BEFORE UPDATE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.guard_store_update();

CREATE TRIGGER guard_store_member_change BEFORE UPDATE OR DELETE ON public.store_members
  FOR EACH ROW EXECUTE FUNCTION private.guard_store_member_change();

-- ---------------------------------------------------------------------------
-- Inventory integrity
-- ---------------------------------------------------------------------------
CREATE TRIGGER record_opening_stock AFTER INSERT ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.record_opening_stock();

CREATE TRIGGER guard_product_stock BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.guard_product_stock();

-- ---------------------------------------------------------------------------
-- Customer balance integrity
-- ---------------------------------------------------------------------------
CREATE TRIGGER guard_customer_balance BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION private.guard_customer_balance();

CREATE TRIGGER apply_customer_ledger AFTER INSERT ON public.customer_transactions
  FOR EACH ROW EXECUTE FUNCTION private.apply_customer_ledger();

-- ---------------------------------------------------------------------------
-- Financial document immutability
-- ---------------------------------------------------------------------------
CREATE TRIGGER guard_sale_change BEFORE UPDATE OR DELETE ON public.sales
  FOR EACH ROW EXECUTE FUNCTION private.guard_sale_change();

CREATE TRIGGER guard_purchase_change BEFORE UPDATE OR DELETE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION private.guard_purchase_change();

-- Append-only ledgers and line items.
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.sale_items
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.purchase_items
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.inventory_adjustments
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.customer_transactions
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.credit_payments
  FOR EACH ROW EXECUTE FUNCTION private.block_write();
CREATE TRIGGER block_write BEFORE UPDATE OR DELETE ON public.audit_logs
  FOR EACH ROW EXECUTE FUNCTION private.block_write();

-- ---------------------------------------------------------------------------
-- Audit trail for master data
-- ---------------------------------------------------------------------------
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.store_members
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.store_settings
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();
CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change();

-- ---------------------------------------------------------------------------
-- Supabase Auth integration
-- ---------------------------------------------------------------------------
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.handle_new_user();

COMMIT;
