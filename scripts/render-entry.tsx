/**
 * Render check for the React application itself.
 *
 * The scenario in `ui-smoke-entry.ts` proves the business rules of the local
 * working model. This file proves the other half: that the real component tree
 * boots, routes and paints. It imports the same `App`, `AppProvider` and page
 * components that `npm run dev` serves and renders them to HTML with
 * `react-dom/server`, so a broken import, a provider used outside its context,
 * a route typo or a page that throws on first render fails here instead of
 * silently in the browser.
 *
 * Rendering is done for three identities:
 *   * a signed-out visitor (the sign-in screen must appear, /billing must not),
 *   * the owner            (every screen, including Settings and Reports),
 *   * the cashier          (the restricted screens must not be offered).
 */
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import { App } from '../src/App';
import { AppProvider } from '../src/app/store';
import type { AppRole } from '../src/lib/types';

export interface RenderCheck {
  name: string;
  ok: boolean;
  detail: string;
}

interface DemoIdentity {
  id: string;
  name: string;
  email: string;
  role: AppRole;
}

/**
 * A browser minimum: `AppProvider` reads `localStorage` while deciding the theme
 * and the signed-in demo user. Everything it touches is stubbed here so the real
 * provider code runs unmodified under Node.
 */
function installStubs(user: DemoIdentity | null) {
  const bag = new Map<string, string>();
  if (user) bag.set('ksm-demo-user', JSON.stringify(user));
  const localStorageStub = {
    getItem: (key: string) => (bag.has(key) ? (bag.get(key) as string) : null),
    setItem: (key: string, value: string) => {
      bag.set(key, String(value));
    },
    removeItem: (key: string) => {
      bag.delete(key);
    },
    clear: () => bag.clear(),
    key: (index: number) => Array.from(bag.keys())[index] ?? null,
    get length() {
      return bag.size;
    },
  };
  (globalThis as unknown as { localStorage: unknown }).localStorage = localStorageStub;
  (globalThis as unknown as { document: unknown }).document = {
    documentElement: { dataset: {} as Record<string, string>, style: {} as Record<string, string> },
    getElementById: () => null,
  };
}

/** Renders the whole application at `path` and returns the HTML. */
function renderApp(path: string): string {
  return renderToString(
    <StaticRouter location={path}>
      <AppProvider>
        <App />
      </AppProvider>
    </StaticRouter>,
  );
}

export function runRenderChecks(): RenderCheck[] {
  const results: RenderCheck[] = [];
  const contains = (name: string, html: string, ...needles: string[]) => {
    const missing = needles.filter((n) => !html.includes(n));
    results.push({
      name,
      ok: missing.length === 0,
      detail:
        missing.length === 0
          ? `all ${needles.length} markers present`
          : `missing from the HTML: ${missing.join(', ')}`,
    });
  };
  const absent = (name: string, html: string, ...needles: string[]) => {
    const present = needles.filter((n) => html.includes(n));
    results.push({
      name,
      ok: present.length === 0,
      detail:
        present.length === 0
          ? 'nothing restricted was rendered'
          : `should not have rendered: ${present.join(', ')}`,
    });
  };
  const renders = (name: string, path: string) => {
    try {
      const html = renderApp(path);
      results.push({ name, ok: html.length > 0, detail: `rendered ${html.length} characters` });
      return html;
    } catch (error) {
      results.push({ name, ok: false, detail: `threw ${(error as Error)?.message ?? String(error)}` });
      return '';
    }
  };

  // -------------------------------------------------------------------------
  // 1. the sign-in screen
  // -------------------------------------------------------------------------
  installStubs(null);
  const login = renders('R01.1 the sign-in screen renders for a visitor', '/login');
  contains(
    'R01.2 the sign-in screen offers all three roles',
    login,
    '<h1>Kirana Store Management</h1>',
    'Enter local demo as owner',
    'Full access: settings, members, everything.',
    'Inventory, purchases, billing, reports.',
    'Billing, sales history, product lookup.',
  );
  contains(
    'R01.3 the sign-in screen explains local demo mode',
    login,
    'Running on localhost with zero setup.',
    'Backend rules (RLS + RPC guards) are mirrored by the demo engine.',
    'href="/settings"',
  );

  // -------------------------------------------------------------------------
  // 2. a signed-out visitor cannot reach an application screen
  // -------------------------------------------------------------------------
  let guardHtml = '';
  let guardError = '';
  try {
    guardHtml = renderApp('/billing');
  } catch (error) {
    guardError = (error as Error)?.message ?? String(error);
  }
  results.push({
    name: 'R02.1 a visitor sent to /billing is redirected, not rendered',
    ok: guardError === '' && !guardHtml.includes('Billing / POS'),
    detail: guardError
      ? `threw ${guardError}`
      : `rendered ${guardHtml.length} characters and no application shell`,
  });
