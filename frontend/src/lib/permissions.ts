import type { AppRole } from './types';

/**
 * The frontend mirror of the RLS matrix in docs/03_rls_matrix.md.
 *
 * This is a UX gate only: it decides which screens and buttons are offered.
 * The authoritative rule lives in the database (RLS policies + RPC role
 * checks), so hiding a button is never the thing that keeps data safe.
 *
 * Action keys map onto the migration surface like this:
 *
 *   action          owner   manager   cashier   database enforcement
 *   ---------------------------------------------------------------------
 *   billing          yes      yes       yes     create_sale (cashier or above)
 *   sales            yes      yes       yes     sales_select_member
 *   products-read    yes      yes       yes     products_select_member
 *   products-write   yes      yes        no     products_write_manager
 *   products-delete  yes       no        no     archive_product (owner/manager)
 *   purchases        yes      yes        no     purchases_select_manager
 *   customers-read   yes      yes       yes*    customers_select_member
 *   customers-write  yes      yes        no     customers_write_manager
 *   payments         yes      yes       yes*    record_customer_payment
 *   reports          yes      yes        no     reporting views (manager+)
 *   members          yes       no        no     invite_store_member (owner)
 *   settings         yes       no        no     update_store_settings (owner)
 *
 *   * cashiers additionally need store_settings.cashier_can_record_payments
 *     for the payment-recording half of customers/payments.
 */
const MANAGER_DENIED = new Set(['members', 'settings']);
const CASHIER_ALLOWED = new Set([
  'billing',
  'sales',
  'products-read',
  'customers-read',
  'payments',
]);

export function can(userRole: AppRole, action: string): boolean {
  if (userRole === 'owner') return true;
  if (userRole === 'manager') return !MANAGER_DENIED.has(action);
  return CASHIER_ALLOWED.has(action);
}
