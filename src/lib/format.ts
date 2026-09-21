export function inr(n: number): string {
  return new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    maximumFractionDigits: 2,
  }).format(n ?? 0);
}

export function num(n: number, digits = 3): string {
  return new Intl.NumberFormat('en-IN', {
    minimumFractionDigits: 0,
    maximumFractionDigits: digits,
  }).format(n ?? 0);
}

export function fmtDate(iso: string): string {
  try {
    return new Intl.DateTimeFormat('en-IN', {
      day: '2-digit',
      month: 'short',
      year: 'numeric',
    }).format(new Date(iso));
  } catch {
    return iso;
  }
}

export function fmtDateTime(iso: string): string {
  try {
    return new Intl.DateTimeFormat('en-IN', {
      day: '2-digit',
      month: 'short',
      hour: '2-digit',
      minute: '2-digit',
    }).format(new Date(iso));
  } catch {
    return iso;
  }
}

export function todayKey(d = new Date()): string {
  return d.toISOString().slice(0, 10);
}

export function uid(prefix = 'id'): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID();
  return `${prefix}-${Math.random().toString(36).slice(2)}${Date.now().toString(36)}`;
}
