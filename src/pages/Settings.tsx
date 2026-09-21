import { useApp } from '../app/store';
import { isSupabaseConfigured } from '../lib/supabase';

export function SettingsPage() {
  const { engine, role, theme, mode, toggleTheme } = useApp();
  return (
    <div className="page">
      <div className="page-head"><div><h2>Settings</h2>
      <p className="muted">Store config, theme and backend connection.</p></div></div>
      <div className="card"><h3>Store</h3>
        <p><strong>{engine?.state.store.name ?? '—'}</strong></p>
        <p className="muted">Invoice prefix {engine?.state.store.invoice_prefix ?? 'INV'} · role {role} · mode {mode}</p>
        <button className="btn sm" onClick={toggleTheme}>Switch to {theme === 'light' ? 'dark' : 'light'} mode</button>
      </div>
      <div className="card"><h3>Supabase connection</h3>
        {isSupabaseConfigured
          ? <p className="muted">Env detected — restart dev server after editing .env.local.</p>
          : <p className="muted">Local demo mode. Copy .env.example to .env.local, add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY, then run migrations in supabase/migrations in order.</p>}
        <ol className="muted">
          <li>Create project, run migrations 001 → 026 in SQL Editor.</li>
          <li>Enable Email auth, sign up, call create_store().</li>
          <li>Invite staff with add_store_member().</li>
          <li>Run supabase/tests/01_rls_and_business_rules.sql to verify.</li>
        </ol>
      </div>
    </div>
  );
}
