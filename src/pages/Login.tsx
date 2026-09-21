import { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { Store, ShieldCheck, Zap, BookOpen } from 'lucide-react';
import { useApp } from '../app/store';
import type { AppRole } from '../lib/types';

export function LoginPage() {
  const { signInDemo, mode } = useApp();
  const navigate = useNavigate();
  const [role, setRole] = useState<AppRole>('owner');

  const enter = () => {
    signInDemo(role);
    navigate('/');
  };

  return (
    <div className="auth-wrap">
      <div className="auth-card">
        <div className="auth-brand">
          <span className="brand-mark lg"><Store size={22} /></span>
          <h1>Kirana Store Management</h1>
          <p>Products, billing, udhaar and reports in one calm workspace.</p>
        </div>

        <div className="role-grid">
          {(['owner', 'manager', 'cashier'] as AppRole[]).map((r) => (
            <button
              key={r}
              className={`role-card${role === r ? ' selected' : ''}`}
              onClick={() => setRole(r)}
              type="button"
            >
              <strong>{r[0].toUpperCase() + r.slice(1)}</strong>
              <small>
                {r === 'owner' && 'Full access: settings, members, everything.'}
                {r === 'manager' && 'Inventory, purchases, billing, reports.'}
                {r === 'cashier' && 'Billing, sales history, product lookup.'}
              </small>
            </button>
          ))}
        </div>

        <button className="btn primary block" onClick={enter} type="button">
          Enter local demo as {role}
        </button>

        <div className="auth-notes">
          <div><ShieldCheck size={14} /> Backend rules (RLS + RPC guards) are mirrored by the demo engine.</div>
          <div><Zap size={14} /> {mode === 'demo' ? 'Running on localhost with zero setup.' : 'Supabase env detected.'}</div>
          <div>
            <BookOpen size={14} />
            <span>Connect a real project: copy <code>.env.example</code> to <code>.env.local</code>. See <Link to="/settings">Settings</Link>.</span>
          </div>
        </div>
      </div>
    </div>
  );
}
