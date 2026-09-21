import { useState } from 'react';
import { useApp } from '../app/store';
import { inr } from '../lib/format';
import { applyCustomerCreate } from '../lib/mutations';

export function CustomersPage() {
  const { engine, refresh, version } = useApp();
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [limit, setLimit] = useState(5000);
  const [payId, setPayId] = useState('');
  const [amount, setAmount] = useState(0);
  const [msg, setMsg] = useState('');
  void version;

  function create() {
    if (!engine || !name.trim()) return;
    applyCustomerCreate(engine.state, {
      store_id: engine.state.store.id, name: name.trim(), phone, credit_limit: limit,
    });
    setName(''); setPhone(''); refresh();
  }

  function pay() {
    if (!engine || !payId) return;
    try {
      const c = engine.recordPayment(payId, amount);
      setMsg(`Collected ${inr(amount)} from ${c.name}. Balance ${inr(c.current_balance)}.`);
      refresh();
    } catch (e) { setMsg((e as Error).message); }
  }

  if (!engine) return <p className="muted">Supabase mode.</p>;
  return (
    <div className="page">
      <div className="page-head"><div><h2>Customers & Udhaar</h2>
      <p className="muted">Balance is ledger-derived; payments only reduce it.</p></div></div>
      {msg && <div className="alert ok">{msg}</div>}
      <div className="card"><div className="inline-form">
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Customer name" />
        <input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="Phone" />
        <input type="number" value={limit} onChange={(e) => setLimit(Number(e.target.value))} placeholder="Limit" />
        <button className="btn primary sm" onClick={create}>Add customer</button>
      </div></div>
      <div className="grid-2">
        <div className="card"><div className="card-head"><h3>Outstanding</h3></div>
          <ul className="rows">{engine.state.customers.map((c) => (
            <li key={c.id}><span><strong>{c.name}</strong>
            <small> · {c.phone} · limit {inr(c.credit_limit)}</small></span>
            <strong>{inr(c.current_balance)}</strong></li>))}</ul></div>
        <div className="card"><div className="card-head"><h3>Collect payment</h3></div>
          <div className="inline-form">
            <select value={payId} onChange={(e) => setPayId(e.target.value)}>
              <option value="">Choose…</option>
              {engine.state.customers.map((c) => <option key={c.id} value={c.id}>{c.name} ({inr(c.current_balance)})</option>)}
            </select>
            <input type="number" value={amount} onChange={(e) => setAmount(Number(e.target.value))} placeholder="Amount" />
            <button className="btn primary sm" onClick={pay}>Record</button>
          </div></div>
      </div>
    </div>
  );
}
