import { useEffect, useState } from 'react';
import { useApp } from '../app/store';
import { inr } from '../lib/format';
import { applyCustomerCreate } from '../lib/mutations';
import { apiGet, apiPost } from '../lib/api';

interface CustomerRow {
  id: string;
  name: string;
  phone: string | null;
  credit_limit: number;
  current_balance: number;
}

export function CustomersPage() {
  const { engine, mode, refresh, version } = useApp();
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [limit, setLimit] = useState(5000);
  const [payId, setPayId] = useState('');
  const [amount, setAmount] = useState(0);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const [rows, setRows] = useState<CustomerRow[] | null>(null);
  void version;

  // Backend mode: GET /api/customers on mount and after every refresh().
  useEffect(() => {
    if (mode !== 'backend') return;
    let alive = true;
    apiGet('customers')
      .then((d: CustomerRow[]) => { if (alive) setRows(d); })
      .catch((e) => { if (alive) setErr((e as Error).message); });
    return () => { alive = false; };
  }, [mode, version]);

  const customers: CustomerRow[] = mode === 'backend'
    ? (rows ?? [])
    : (engine?.state.customers ?? []);

  async function create() {
    if (!name.trim()) return;
    setErr('');
    if (mode === 'backend') {
      try {
        await apiPost('customers', {
          name: name.trim(),
          phone: phone.trim() || undefined,
          credit_limit: limit,
        });
        setName(''); setPhone('');
        refresh();
      } catch (e) {
        setErr((e as Error).message);
      }
      return;
    }
    if (!engine) return;
    applyCustomerCreate(engine.state, {
      store_id: engine.state.store.id, name: name.trim(), phone, credit_limit: limit,
    });
    setName(''); setPhone(''); refresh();
  }

  async function pay() {
    if (!payId) return;
    setErr('');
    if (mode === 'backend') {
      try {
        await apiPost(`customers/${payId}/pay`, { amount, payment_method: 'cash' });
        setMsg(`Collected ${inr(amount)}. Balance updated from the ledger.`);
        refresh();
      } catch (e) {
        setErr((e as Error).message);
      }
      return;
    }
    if (!engine) return;
    try {
      const c = engine.recordPayment(payId, amount);
      setMsg(`Collected ${inr(amount)} from ${c.name}. Balance ${inr(c.current_balance)}.`);
      refresh();
    } catch (e) { setMsg((e as Error).message); }
  }

  return (
    <div className="page">
      <div className="page-head"><div><h2>Customers & Udhaar</h2>
      <p className="muted">Balance is ledger-derived; payments only reduce it.</p></div></div>
      {msg && <div className="alert ok">{msg}</div>}
      {err && <div className="alert err">{err}</div>}
      {mode === 'backend' && rows === null && !err && <p className="muted">Loading customers…</p>}
      <div className="card"><div className="inline-form">
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Customer name" />
        <input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="Phone" />
        <input type="number" value={limit} onChange={(e) => setLimit(Number(e.target.value))} placeholder="Limit" />
        <button className="btn primary sm" onClick={create}>Add customer</button>
      </div></div>
      <div className="grid-2">
        <div className="card"><div className="card-head"><h3>Outstanding</h3></div>
          <ul className="rows">{customers.map((c) => (
            <li key={c.id}><span><strong>{c.name}</strong>
            <small> · {c.phone} · limit {inr(c.credit_limit)}</small></span>
            <strong>{inr(c.current_balance)}</strong></li>))}</ul></div>
        <div className="card"><div className="card-head"><h3>Collect payment</h3></div>
          <div className="inline-form">
            <select value={payId} onChange={(e) => setPayId(e.target.value)}>
              <option value="">Choose…</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.name} ({inr(c.current_balance)})</option>)}
            </select>
            <input type="number" value={amount} onChange={(e) => setAmount(Number(e.target.value))} placeholder="Amount" />
            <button className="btn primary sm" onClick={pay}>Record</button>
          </div></div>
      </div>
    </div>
  );
}