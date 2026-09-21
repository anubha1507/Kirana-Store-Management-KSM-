export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

// Minimal typed surface for the Supabase client. The database contract lives
// in supabase/migrations; this file only keeps TypeScript honest in the
// frontend without requiring a generated types file.
export interface Database {
  public: {
    Tables: {
      products: { Row: Record<string, unknown> };
      sales: { Row: Record<string, unknown> };
      customers: { Row: Record<string, unknown> };
      daily_sales_summary: { Row: Record<string, unknown> };
      product_sales_summary: { Row: Record<string, unknown> };
      customer_outstanding_balances: { Row: Record<string, unknown> };
      low_stock_products: { Row: Record<string, unknown> };
      inventory_valuation: { Row: Record<string, unknown> };
    };
    Views: {
      daily_sales_summary: { Row: Record<string, unknown> };
      product_sales_summary: { Row: Record<string, unknown> };
      customer_outstanding_balances: { Row: Record<string, unknown> };
      low_stock_products: { Row: Record<string, unknown> };
      inventory_valuation: { Row: Record<string, unknown> };
    };
    Functions: {
      create_sale: { Args: Record<string, unknown>; Returns: unknown };
      create_purchase: { Args: Record<string, unknown>; Returns: unknown };
      record_customer_payment: { Args: Record<string, unknown>; Returns: unknown };
      cancel_sale: { Args: Record<string, unknown>; Returns: unknown };
      find_products_for_billing: { Args: Record<string, unknown>; Returns: unknown };
      find_customers_for_billing: { Args: Record<string, unknown>; Returns: unknown };
    };
  };
}
