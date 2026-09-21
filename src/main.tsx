import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { App } from './App';
import { AppProvider } from './app/store';
import './styles.css';

const el = document.getElementById('root');
if (!el) throw new Error('Missing #root element in index.html');

createRoot(el).render(
  <BrowserRouter>
    <AppProvider>
      <App />
    </AppProvider>
  </BrowserRouter>,
);
