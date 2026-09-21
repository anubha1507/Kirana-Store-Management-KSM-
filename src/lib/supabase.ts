import { createClient } from '@supabase/supabase-js';
import type { Database } from './database.types';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const isSupabaseConfigured = Boolean(url && anonKey);

let client: ReturnType<typeof createClient<Database>> | null = null;

export function getSupabase() {
  if (!isSupabaseConfigured || !url || !anonKey) return null;
  if (!client) {
    client = createClient<Database>(url, anonKey, {
      auth: { persistSession: true, autoRefreshToken: true },
    });
  }
  return client;
}
