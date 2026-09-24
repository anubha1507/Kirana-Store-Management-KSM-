import { useApp } from '../app/store';
import { isBackendConfigured, apiBase } from '../lib/api';

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
      <div className="card"><h3>Backend connection</h3>
        {isBackendConfigured ? (
          <>
            <p className="muted">
              Talking to <strong>{apiBase}</strong>. Edit <code>frontend/.env</code> (or <code>.env.local</code>)
              and restart <code>npm run dev</code> to change it — no secrets in the frontend.
            </p>
            <ol className="muted">
              <li>Schema: the SQL migrations (001 → 028) and the consolidated backend/database/schema.sql.</li>
              <li>Start the API (cd backend &amp;&amp; npm run dev), then sign up at /login — first account becomes owner + store.</li>
              <li>Frontend connects through VITE_API_BASE_URL (http://localhost:5000/api).</li>
              <li>Verify DB rules anytime with npm run validate:db (PGlite, no server needed).</li>
            </ol>
          </>
        ) : (
          <p className="muted">
            Local demo mode. Copy <code>frontend/.env.example</code> to <code>frontend/.env</code>,
            set <code>VITE_API_BASE_URL=http://localhost:5000/api</code>, then restart the dev server.
          </p>
        )}
      </div>
    </div>
  );
}