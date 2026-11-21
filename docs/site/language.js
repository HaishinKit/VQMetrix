(() => {
  'use strict';
  const base = '/VQMetrix';
  const translated = new Set(__VQ_TRANSLATED_ROUTES__);
  const key = 'vqmetrix.language';
  const valid = value => value === 'en' || value === 'ja';
  const route = pathname => {
    if (!pathname.startsWith(base + '/')) return null;
    let path = pathname.slice(base.length).replace(/index\.html$/, '');
    if (!path.endsWith('/')) path += '/';
    const japanese = path.startsWith('/ja/');
    const canonical = japanese ? path.slice(3) : path;
    if (canonical !== '/' && !canonical.startsWith('/swift/')) return null;
    return { canonical, language: japanese ? 'ja' : 'en' };
  };
  const stored = () => { try { return localStorage.getItem(key); } catch { return null; } };
  const remember = language => { try { localStorage.setItem(key, language); } catch {} };
  const urlFor = (url, language) => {
    const current = route(url.pathname);
    if (!current) return null;
    const actual = language === 'ja' && translated.has(current.canonical) ? 'ja' : 'en';
    const destination = new URL(url.href);
    destination.pathname = base + (actual === 'ja' ? '/ja' : '') + current.canonical;
    return destination;
  };
  const current = route(location.pathname);
  if (!current) return;
  const requested = new URL(location.href).searchParams.get('lang');
  const preference = valid(requested) ? requested : stored();
  const browserLanguage = (navigator.languages && navigator.languages[0]) || navigator.language || 'en';
  const language = valid(preference) ? preference : /^ja(?:-|$)/i.test(browserLanguage) ? 'ja' : 'en';
  if (valid(requested)) remember(requested);
  const destination = urlFor(new URL(location.href), language);
  if (destination && destination.pathname !== location.pathname.replace(/index\.html$/, '')) {
    location.replace(destination.href);
    return;
  }
  document.addEventListener('click', event => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest && event.target.closest('a[href]');
    if (!link) return;
    const url = new URL(link.href, location.href);
    if (url.origin !== location.origin) return;
    const target = route(url.pathname);
    if (!target) return;
    const label = (link.textContent || '').trim();
    const explicit = valid(link.lang) ? link.lang : label === 'English' ? 'en' : label === '日本語' ? 'ja' : null;
    if (!explicit) return;
    const next = urlFor(url, explicit);
    if (!next) return;
    remember(explicit);
    next.searchParams.set('lang', explicit);
    if (!next.hash && target.canonical === current.canonical) next.hash = location.hash;
    event.preventDefault();
    location.assign(next.href);
  }, true);
})();
