import { useState } from 'react';
import type { FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Store, ShieldCheck, Zap, BookOpen } from 'lucide-react';
import { useApp } from '../app/store';
import type { AppRole } from '../lib/types';

export function LoginPage() {
  const { signInDemo, signInBackend, signUpBackend, mode } = useApp();
  const navigate = useNavigate();
  const [role, setRole] = useState<AppRole>('owner');
  const [tab, setTab] = useState<'login' | 'signup'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [fullName, setFullName] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const enterDemo = () => {
    signInDemo(role);
    navigate('/');
  };

  async function submitBackend(e: FormEvent) {
    e.preventDefault();
    setErr('');
    setBusy(true);
    try {
      if (tab === 'login') {
        await signInBackend(email.trim(), password);
      } else {
        await signUpBackend(email.trim(), password, fullName.trim(), role);
      }
      navigate('/');
    } catch (error) {
      setErr((error as Error).message || 'Sign-in failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="auth-wrap">
      <div className="auth-card">
        <div className="auth-brand">
          <span className="brand-mark lg"><Store size={22} /></span>
          <h1>Kirana Store Management</h1>
          <p>Products, billing, udhaar and reports in one calm workspace.</p>
        </div>

        {mode === 'backend' ? (
          <form onSubmit={submitBackend}>
            {err && <div className="alert err">{err}</div>}
            <div className="role-grid">
              <button
                type="button"
                className={`role-card${tab === 'login' ? ' selected' : ''}`}
                onClick={() => setTab('login')}
              >
                <strong>Sign in</strong>
                <small>Use your backend account (POST /api/auth/login).</small>
              </button>
              <button
                type="button"
                className={`role-card${tab === 'signup' ? ' selected' : ''}`}
                onClick={() => setTab('signup')}
              >
                <strong>Create account</strong>
                <small>First signup creates the owner + store (POST /api/auth/signup).</small>
              </button>
            </div>
            <div className="form-grid">
              {tab === 'signup' && (
                <label>Full name
                  <input value={fullName} onChange={(e) => setFullName(e.target.value)} placeholder="Ramesh Sharma" autoComplete="name" required />
                </label>
              )}
              <label>Email
                <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="owner@example.com" autoComplete="email" required />
              </label>
              <label>Password
                <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="At least 8 characters" autoComplete={tab === 'login' ? 'current-password' : 'new-password'} minLength={tab === 'signup' ? 8 : undefined} required />
              </label>
              {tab === 'signup' && (
                <label>Role
                  <select value={role} onChange={(e) => setRole(e.target.value as AppRole)}>
                    <option value="owner">Owner</option>
                    <option value="manager">Manager</option>
                    <option value="cashier">Cashier</option>
                  </select>
                </label>
              )}
            </div>
            <button className="btn primary block" type="submit" disabled={busy || !email.trim() || !password}>
              {busy ? 'Working…' : tab === 'login' ? 'Sign in to backend' : 'Create account'}
            </button>
          </form>
        ) : (
          <>
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
            <button className="btn primary block" onClick={enterDemo} type="button">
              Enter local demo as {role}
            </button>
          </>
        )}

        <div className="auth-notes">
          <div><ShieldCheck size={14} /> {mode === 'backend' ? 'All data is validated server-side (RPC guards + ledger rules).' : 'Backend rules (RLS + RPC guards) are mirrored by the demo engine.'}</div>
          <div><Zap size={14} /> {mode === 'demo' ? 'Running on localhost with zero setup.' : 'Backend API configured — every list and write goes through REST.'}</div>
          <div>
            <BookOpen size={14} />
            <span>
              Switch modes by editing <code>frontend/.env</code> (set or clear <code>VITE_API_BASE_URL</code>). See <Link to="/settings">Settings</Link>.
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}