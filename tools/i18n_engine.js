// Жол — переводчик интерфейса RU → KK / EN (движок). Словарь — в i18n.js (window.ZHOL_I18N_DICT).
(() => {
'use strict';
const LS_KEY = 'zhol_lang';
const LANGS = ['ru', 'kk', 'en'];
let LANG = (() => { try { const v = localStorage.getItem(LS_KEY); return LANGS.includes(v) ? v : 'ru'; } catch { return 'ru'; } })();
const D = () => window.ZHOL_I18N_DICT || {};
const CITY = () => window.ZHOL_CITY_NAMES || {};     // id -> {ru, kk, en}
const L = /[A-Za-zА-Яа-яЁёӘәҒғҚқҢңӨөҰұҮүҺһІі]/;

/* ---------- казахские падежи (сингармонизм) ---------- */
const BACK = 'аоұыуя', FRONT = 'әөүіеэиюё';
function kkBack(w) { const s = w.toLowerCase(); for (let i = s.length - 1; i >= 0; i--) { const ch = s[i]; if ('аоұы'.includes(ch)) return true; if ('әөүіе'.includes(ch)) return false; } for (let i = s.length - 1; i >= 0; i--) { const ch = s[i]; if (BACK.includes(ch)) return true; if (FRONT.includes(ch)) return false; } return true; }
function kkCase(w, c) {
  if (!c || c === 'nom') return w;
  const b = kkBack(w), last = w.toLowerCase().slice(-1);
  const vowel = 'аәеёиоөуұүыіэюя'.includes(last), nasal = 'мнң'.includes(last), sonor = 'рлйуз'.includes(last) || last === 'ж', voiceless = 'кқпстфхцчшщбвгд'.includes(last);
  const A = b ? 'а' : 'е', Y = b ? 'ы' : 'і';
  if (c === 'loc') return w + (voiceless ? 'т' : 'д') + A;                         // Алматыда, Шымкентте
  if (c === 'locsyn') return kkCase(w, 'loc') + (b ? 'сың' : 'сің');                // Тараздасың, Өскемендесің
  if (c === 'locadj') return kkCase(w, 'loc') + (b ? 'ғы' : 'гі');                    // Қордайдағы
  if (c === 'dat') return w + (voiceless ? (b ? 'қа' : 'ке') : (b ? 'ға' : 'ге'));  // Таразға, Шымкентке
  if (c === 'abl') return w + (voiceless ? 'т' : nasal ? 'н' : 'д') + A + 'н';       // Тараздан, Өскеменнен, Шымкенттен
  if (c === 'gen') return w + (vowel ? 'н' : nasal || sonor ? 'д' : 'т') + Y + 'ң';  // Алматының, Таразның? -> Тараздың
  return w;
}
/* ---------- русские формы названий городов -> id ---------- */
function ruForms(s) {
  const f = new Set([s]);
  const cons = /[бвгджзклмнпрстфхцчшщ]$/;
  if (/й$/.test(s)) { const b = s.slice(0, -1); ['я', 'ю', 'ем', 'е'].forEach(e => f.add(b + e)); }
  else if (/а$/.test(s)) { const b = s.slice(0, -1); ['ы', 'и', 'е', 'у', 'ой'].forEach(e => f.add(b + e)); }
  else if (cons.test(s)) { ['а', 'у', 'е', 'ом'].forEach(e => f.add(s + e)); if (/ск$/.test(s)) {} }
  return [...f];
}
const SAMPLE_NAMES = ['Аружан', 'Нурали', 'Айсултан', 'Аниса', 'Амир', 'Аиша', 'Тамила', 'Арлан', 'Айзере', 'Тест (Асет)'];
let CITY_RE = null, CITY_MAP = {}, NAMES = [], NAME_RE = null;
function buildCity() {
  CITY_MAP = {};
  const C = CITY();
  for (const id in C) for (const form of ruForms(C[id].ru)) CITY_MAP[form] = id;
  const forms = Object.keys(CITY_MAP).sort((a, b) => b.length - a.length).map(x => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  CITY_RE = forms.length ? new RegExp('(^|[^\\p{L}])(' + forms.join('|') + ')(?=[^\\p{L}]|$)', 'gu') : null;
}
function setNames(list) {
  NAMES = [...new Set([...SAMPLE_NAMES, ...(list || [])].filter(Boolean))].sort((a, b) => b.length - a.length);
  const alt = NAMES.map(x => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  // имя с аватаркой-эмодзи перед ним, список имён через запятую — одним токеном
  const one = `(?:[^\\p{L}\\p{N}\\s«»"(){}.,:;!?—–-]+\\s)?(?:${alt.join('|')})`;
  NAME_RE = alt.length ? new RegExp(`(^|[^\\p{L}])(${one}(?:,\\s${one})*)(?=[^\\p{L}]|$)`, 'gu') : null;
  CACHE.clear(); D2 = null;
}
const NUM_RE = /\{[a-z]\d+(?::\w+)?\}|\d+(?:[\u00a0\u202f ,]\d{3}(?!\d))*(?:\.\d+|,\d{1,2}(?!\d))?/g;
const CACHE = new Map();
const MISS = new Set();
function cityName(id, c) { const C = CITY()[id]; if (!C) return id; const n = C[LANG] || C.ru; return LANG === 'kk' ? kkCase(n, c) : n; }
const enNum = x => x.replace(/[\u00a0\u202f ](?=\d{3})/g, ',').replace(/,(\d{1,2})$/, '.$1');
function fill(tpl, v) {
  return tpl.replace(/\{([npcq])(\d+)(?::(\w+))?\}/g, (m, t, i, c) => {
    const x = v[t][+i]; if (x == null) return m;
    if (t === 'c') return x.ids.map((id, j) => cityName(id, j === x.ids.length - 1 ? c : 'nom')).join(x.sep);
    if (t === 'n' && LANG === 'en') return enNum(x);
    if (t === 'q') { const m = x.match(/^([\s\S]*?)«([\s\S]*)»$/); if (m) { const inner = trAny(m[2], 3); return m[1] + '«' + inner + '»'; } }
    return x;
  });
}
function templ(s, q) {
  const v = { n: [], p: [], c: [], q: [] };
  let t = s;
  if (q) t = t.replace(/(?:[^\p{L}\p{N}\s«»{}]+\s)?«[^«»]{1,80}»/gu, m => '{q' + (v.q.push(m) - 1) + '}');
  if (NAME_RE) t = t.replace(NAME_RE, (m, pre, name) => pre + '{p' + (v.p.push(name) - 1) + '}');
  if (CITY_RE) t = t.replace(CITY_RE, (m, pre, name) => pre + '{c' + (v.c.push({ ids: [CITY_MAP[name]], sep: ', ' }) - 1) + '}');
  // список городов «{c0}, {c1}» или маршрут «{c0} → {c1} → {c2}» — один токен
  t = t.replace(/\{c(\d+)\}(?:(, | → )\{c\d+\})+/g, (m, i0, sep) => { const ids = [...m.matchAll(/\{c(\d+)\}/g)].map(x => v.c[+x[1]].ids[0]); return '{c' + (v.c.push({ ids, sep }) - 1) + '}'; });
  let k = 0; const cc = []; t = t.replace(/\{c(\d+)\}/g, (m, i) => { cc.push(v.c[+i]); return '{c' + (k++) + '}'; }); v.c = cc;
  t = t.replace(NUM_RE, m => m[0] === '{' ? m : '{n' + (v.n.push(m) - 1) + '}');
  return [t, v];
}
/* ---------- словарь: образцы -> шаблоны ---------- */
let D2 = null;
const digits = x => x.replace(/[^\d]/g, '');
function compile() {
  D2 = new Map();
  for (const [ru, kk, en] of (window.ZHOL_I18N_DICT || [])) {
    const useQ = /\{q\d\}/.test(kk + en);
    const [tk, v] = templ(ru, useQ);
    if (/^\{[pc]0\}$/.test(tk)) continue;   // ключ — только имя или город: не переводим словарём   // ключ только из имён/городов — пропускаем
    const conv = val => { const used = new Set(); return val.replace(NUM_RE, m => { if (m[0] === '{') return m; const i = v.n.findIndex((x, j) => !used.has(j) && digits(x) === digits(m)); if (i < 0) return m; used.add(i); return '{n' + i + '}'; }); };
    const key = (useQ ? 'Q|' : '') + tk;
    if (!D2.has(key)) D2.set(key, [conv(kk), conv(en)]);
  }
}
function look(core) {
  if (!CITY_RE) buildCity(); if (!NAME_RE) setNames([]);
  if (!D2) compile();
  const C = CITY(); for (const id in C) if (C[id].ru === core) return C[id][LANG];
  let [t, v] = templ(core);
  let e = D2.get(t);
  if (!e && core.includes('«')) { [t, v] = templ(core, true); e = D2.get('Q|' + t); }
  if (e) return fill(LANG === 'kk' ? e[0] : e[1], v);
  if (/^\{c0\}$/.test(t)) return fill('{c0}', v);
  if (/^\{p0\}$/.test(t)) return core;
  return null;
}
const PRE = /^[\s\u00a0]*(?:[^\p{L}\p{N}«"(\[{@+\-−–—]+[\s\u00a0]*)?/u, POST = /[\s\u00a0]*(?:[^\p{L}\p{N}»")\]}.!?…%]+)?[\s\u00a0]*$/u;
const NOTR = s => { const [t] = templ(s); return /^[\s\p{P}\p{S}]*\{[pcq]0\}[\s\p{P}\p{S}]*$/u.test(t); };
// делим по разделителю, но не внутри (скобок) и «кавычек»
function splitSmart(s, sep) {
  const raw = s.split(sep), out = [];
  const open = x => (x.split('(').length - x.split(')').length) + (x.split('«').length - x.split('»').length);
  for (const p of raw) { if (out.length && open(out[out.length - 1]) > 0) out[out.length - 1] += sep + p; else out.push(p); }
  return out;
}
function trCore(s, depth) {
  if (!L.test(s)) return s;
  let r = look(s); if (r != null) return r;
  // отрезаем эмодзи/значки в начале и в конце
  const pm = s.match(PRE)[0], rest = s.slice(pm.length), qm = rest.match(POST)[0], core = rest.slice(0, rest.length - qm.length);
  if (core && (pm || qm)) { r = look(core); if (r != null) { const a = pm.trim(), z = qm.trim(); return (a && r.startsWith(a) ? '' : pm) + r + (z && r.endsWith(z) ? '' : qm); } }
  if (/[^.]\.$/.test(s) && !/[.?!] /.test(s)) { r = trCore(s.slice(0, -1), depth + 1); if (r != null) return r + (/[.!?]$/.test(r) ? '' : '.'); }
  if (depth > 2) return null;
  let best = null, bestOk = 0, bestBad = [];
  for (const sep of ['. ', '? ', '! ', '; ', ' · ', ' — ', ': ', ' (', ', ']) {
    if (!s.includes(sep)) continue;
    const parts = splitSmart(s, sep); if (parts.length < 2) continue; let ok = 0, bad = 0, out; const badP = [];
    const one = pp => { const x = trAny(pp, depth + 1, true); if (x !== pp) ok++; else if (L.test(pp) && /[А-Яа-яЁё]/.test(pp) && !(LANG === 'kk' && /[әғқңөұүһіӘҒҚҢӨҰҮҺІ]/.test(pp)) && !NOTR(pp)) { bad++; badP.push(pp); } return x; };
    if ('.?!'.includes(sep[0])) out = parts.map((p, i) => one(i < parts.length - 1 ? p + sep[0] : p)).join(' ');
    else out = parts.map((p, i) => { const pp = sep === ' (' && i > 0 ? '(' + p : p; const x = one(pp); return sep === ' (' && i > 0 ? x.replace(/^\(/, '') : x; }).join(sep);
    if (ok && !bad) return out;
    if (ok > bestOk) { best = out; bestOk = ok; bestBad = badP; }
  }
  if (best != null && depth === 0) bestBad.forEach(p => MISS.add(templ(p.trim())[0]));
  return best;
}
function trAny(s, depth = 0, quiet) {
  const lead = s.match(/^[\s\u00a0]*/)[0], tail = s.match(/[\s\u00a0]*$/)[0], core = s.trim();
  if (!core) return s;
  const r = trCore(core, depth);
  if (r == null) { if (!quiet && L.test(core) && /[А-Яа-яЁё]/.test(core) && !(LANG === 'kk' && /[әғқңөұүһіӘҒҚҢӨҰҮҺІ]/.test(core))) MISS.add(templ(core)[0]); return s; }
  return lead + r + tail;
}
function tr(s) {
  if (LANG === 'ru' || s == null) return s;
  s = String(s);
  if (CACHE.has(s)) return CACHE.get(s);
  const r = trAny(s); CACHE.set(s, r); return r;
}
/* ---------- DOM ---------- */
const SKIP = 'script,style,textarea,input,[data-nt],.nt,.ct:not(.del),.enword,.enru,.enex,.enhint,.enkk,.qopt-nt';
const DONE = new WeakMap();
function trText(n) {
  const v = n.nodeValue; if (!v || DONE.get(n) === v) return;
  const p = n.parentElement; if (p && p.closest(SKIP)) return;
  const r = tr(v); DONE.set(n, r); if (r !== v) n.nodeValue = r;
}
const ATTRS = ['placeholder', 'title', 'aria-label'];
function trEl(el) {
  if (el.closest && el.closest('[data-nt],.nt')) return;
  for (const a of ATTRS) if (el.hasAttribute && el.hasAttribute(a)) { const v = el.getAttribute(a), k = '__i18n_' + a; if (el[k] === v) continue; const r = tr(v); el[k] = r; if (r !== v) el.setAttribute(a, r); }
}
function walk(root) {
  if (root.nodeType === 3) return trText(root);
  if (root.nodeType !== 1) return;
  trEl(root);
  if (root.closest && root.closest(SKIP) && root.tagName !== 'BODY') return;
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, { acceptNode: n => { if (n.nodeType === 1 && n.matches(SKIP)) { if (/^(INPUT|TEXTAREA)$/.test(n.tagName)) trEl(n); return NodeFilter.FILTER_REJECT; } return NodeFilter.FILTER_ACCEPT; } });
  let n; while ((n = w.nextNode())) { if (n.nodeType === 3) trText(n); else trEl(n); }
}
let obs = null;
function start() {
  document.documentElement.lang = LANG === 'kk' ? 'kk' : LANG;
  if (LANG === 'ru') return;
  buildCity(); if (!NAME_RE) setNames([]);
  walk(document.body); document.title = tr(document.title);
  obs = new MutationObserver(ms => { for (const m of ms) { if (m.type === 'characterData') trText(m.target); else if (m.type === 'attributes') trEl(m.target); else m.addedNodes.forEach(walk); } });
  obs.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  const oc = window.confirm.bind(window), oa = window.alert.bind(window), op = window.prompt.bind(window);
  window.confirm = m => oc(tr(m)); window.alert = m => oa(tr(m)); window.prompt = (m, d) => op(tr(m), d);
}
function setLang(l) { if (!LANGS.includes(l) || l === LANG) return; try { localStorage.setItem(LS_KEY, l); } catch {} location.reload(); }
window.I18N = { get lang() { return LANG; }, tr, setLang, setNames, kkCase, cityName: (id, c) => cityName(id, c), miss: () => [...MISS], LANGS,
  locale: () => LANG === 'kk' ? 'kk-KZ' : LANG === 'en' ? 'en-GB' : 'ru-RU', t: (ru, kk, en) => LANG === 'kk' ? kk : LANG === 'en' ? en : ru };
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
