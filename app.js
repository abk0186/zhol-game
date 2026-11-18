(() => {
'use strict';
const Z = window.ZHOL;
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const LS = { get(k, d) { try { const v = JSON.parse(localStorage.getItem(k)); return v ?? d; } catch { return d; } }, set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} }, del(k) { localStorage.removeItem(k); } };
const fmt = n => Number(n || 0).toLocaleString('ru-RU', { maximumFractionDigits: 1 });
const rnd = (a, b) => a + Math.random() * (b - a);
const pick = a => a[Math.floor(Math.random() * a.length)];

let PUB = LS.get('zhol_pub', null);
let SESSION = LS.get('zhol_me', null);
let ME = null, REQS = [], ADMIN = null, PIN = null, TAB = 'map';
let FAM = LS.get('zhol_fam', null), FAMDATA = null;

/* ---------- сеть ---------- */
function setNet(ok) { $('#net').classList.toggle('hidden', ok); }
async function rpc(fn, args) {
  let r;
  try {
    r = await fetch(`${Z.SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: Z.SUPABASE_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}) });
  } catch (e) { setNet(false); const err = new Error('offline'); err.offline = true; throw err; }
  setNet(true);
  if (!r.ok) throw new Error('Ошибка сервера ' + r.status);
  return r.json();
}
const ERR = { bad_code: 'Неверный код', locked: 'Слишком много попыток. Подожди 5 минут', bad_pin: 'Неверный PIN', no_ticket: 'Нужен билет 🎫', not_enough: 'Не хватает жетонов', too_many: 'Слишком много запросов ждут ответа', already: 'Уже отправлено', bad_path: 'Такой дороги нет', too_fast: 'Слишком быстро — это не засчитано', bad_steps: 'Минимум 100 шагов', bad_format: 'Неверный формат', on_trip: 'Кто-то из вас уже в пути', not_same_place: 'Вы должны быть в одном месте', has_challenge: 'У кого-то из вас уже есть жарыс', no_challenge: 'Вызов уже не действует', bad_transport: 'Этот транспорт нельзя', no_player: 'Нет такого игрока', no_rail: 'Здесь нет железной дороги', no_flight: 'Нет прямого рейса', no_stop: 'Сначала доедь до остановки', in_race: 'Во время жарыса пересаживаться нельзя', locked_city: 'Этот город пока закрыт 🔒 — открой его добрыми делами ⭐', deed_limit: 'На сегодня хватит: не больше 10 дел в день 🌙', deed_cap: 'По этому делу на сегодня звёзд уже максимум — завтра ещё!', bad_cat: 'Выбери, что ты сделал(а)', bad_amount: 'Проверь число', too_long: 'Комментарий — до 200 символов' };
const errText = e => ERR[e] || e || 'Что-то пошло не так';

/* ---------- граф ---------- */
const nodes = () => Object.fromEntries((PUB?.nodes || []).map(n => [n.id, n]));
const nname = id => nodes()[id]?.name || id;
/* ---------- края и замки (добрые дела) ---------- */
const DEEDS = () => PUB?.config?.deeds || { cats: {}, regions: [] };
const REGS = () => DEEDS().regions || [];
const regOf = id => nodes()[id]?.region || null;
const regInfo = rid => REGS().find(r => r.id === rid) || { id: rid, n: rid, e: '🔒', need: 0 };
const regCities = rid => (PUB?.nodes || []).filter(n => n.region === rid);
// открыт ли город для ребёнка (то же правило проверяет сервер)
const isOpen = (id, who = ME) => { const r = regOf(id); return !r || !!who?.unlocked?.includes(r); };
const openFor = who => who ? (id => isOpen(id, who)) : (() => true);
function adj(mode, ok = () => true) {
  const g = {};
  for (const e of PUB.edges) if (e.mode === mode && ok(e.a) && ok(e.b)) { (g[e.a] ||= []).push([e.b, +e.km]); (g[e.b] ||= []).push([e.a, +e.km]); }
  return g;
}
function shortest(from, to, ok = openFor(ME)) {
  const g = adj('road', ok), dist = { [from]: 0 }, prev = {}, done = new Set();
  while (true) {
    let u = null; for (const k in dist) if (!done.has(k) && (u === null || dist[k] < dist[u])) u = k;
    if (u === null) return null;
    if (u === to) break; done.add(u);
    for (const [v, w] of g[u] || []) if (dist[u] + w < (dist[v] ?? Infinity)) { dist[v] = dist[u] + w; prev[v] = u; }
  }
  const path = [to]; while (path[0] !== from) path.unshift(prev[path[0]]);
  return { path, km: dist[to] };
}
const airKm = (a, b) => { const e = PUB.edges.find(e => e.mode === 'air' && ((e.a === a && e.b === b) || (e.a === b && e.b === a))); return e ? +e.km : null; };
const locName = id => { const s = nname(id); return /[йя]$/.test(s) ? s.slice(0, -1) + 'е' : /а$/.test(s) ? s.slice(0, -1) + 'е' : /[бвгджзклмнпрстфхцчшщ]$/.test(s) ? s + 'е' : s; };
const genName = id => { const s = nname(id); return /й$/.test(s) ? s.slice(0, -1) + 'я' : /[кгхжшчщ]а$/.test(s) ? s.slice(0, -1) + 'и' : /а$/.test(s) ? s.slice(0, -1) + 'ы' : /[бвгджзклмнпрстфхцчшщ]$/.test(s) ? s + 'а' : s; };
const isRail = (a, b) => PUB.edges.some(e => e.mode === 'road' && e.rail && ((e.a === a && e.b === b) || (e.a === b && e.b === a)));
const hasRail = id => PUB.edges.some(e => e.mode === 'road' && e.rail && (e.a === id || e.b === id));
// доступность транспорта на маршруте (то же правило проверяет сервер)
function trAvail(id, from, to, path) {
  if (id === 'plane') {
    const N = nodes();
    if (!N[from]?.airport) return 'в ' + locName(from) + ' нет аэропорта';
    if (!N[to]?.airport) return 'в ' + locName(to) + ' нет аэропорта';
    if (!airKm(from, to)) return 'нет прямого рейса';
    if (!isOpen(to)) return 'город закрыт 🔒';
    if (ME.tickets < 1) return 'нужен билет 🎫';
  }
  if (id === 'train') {
    const bad = path.find(n => !hasRail(n)); if (bad) return 'в ' + locName(bad) + ' нет железной дороги';
    for (let i = 0; i + 1 < path.length; i++) if (!isRail(path[i], path[i + 1])) return 'нет железной дороги ' + nname(path[i]) + ' — ' + nname(path[i + 1]);
  }
  return '';
}
function trRows(from, to, r, skip) {
  const m = mult(ME.age), air = airKm(from, to);
  return Object.entries(Z.TRANSPORT).filter(([id]) => id !== skip).map(([id, T]) => {
    let est, km = r.km; const why = trAvail(id, from, to, r.path), dis = !!why;
    if (id === 'plane') km = air || km;
    const mm = T.noAge ? 1 : m;
    if (T.engine === 'tap' || T.engine === 'alt' || T.engine === 'beat') est = `≈ ${fmt(Math.ceil(km / (T.perTap * mm)))} тапов`;
    else { const sec = km / (T.perSec * mm); est = sec < 120 ? `≈ ${Math.ceil(sec)} сек` : `≈ ${Math.ceil(sec / 60)} мин`; }
    const bonus = id === 'horse' && r.path.includes('KOR') ? ' · ×1.5 жетона рядом с Кордаем' : '';
    return `<button class="opt${dis ? ' off' : ''}" data-tr="${id}" ${dis ? 'disabled' : ''}><span class="i">${T.icon}</span><span><b>${T.name}</b><small>${dis ? '🚫 ' + esc(why) : fmt(km) + ' км · ' + est + bonus}</small></span></button>`;
  }).join('');
}
const interStops = trip => { let cum = 0; return trip.path.map((n, i) => { if (i > 0) cum += +trip.legs[i - 1]; return { n, at: cum, i }; }).slice(1, -1); };
const mult = age => age <= 11 ? 1.6 : age <= 14 ? 1.25 : 1.0;
function weekGoal() { let s = 0; for (const p of PUB.players) { const r = shortest(p.home, 'KOR', openFor(p)); s += r ? r.km : 0; } return s; }
function tripPos(trip, doneOverride) {
  const done = doneOverride ?? +trip.done; let cum = 0;
  for (let i = 0; i < trip.legs.length; i++) {
    const L = +trip.legs[i];
    if (done <= cum + L || i === trip.legs.length - 1) {
      const f = Math.max(0, Math.min(1, (done - cum) / L)), a = Z.XY[trip.path[i]], b = Z.XY[trip.path[i + 1]];
      return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
    }
    cum += L;
  }
  return Z.XY[trip.path.at(-1)];
}

/* ---------- модалка, тост ---------- */
let SHEET_LOCKED = false;
function sheet(html, onClose) { SHEET_LOCKED = onClose === false; $('#sheet').innerHTML = `<div class="sheet-bar"><button class="home-btn" data-home>🏠 Домой</button>${SHEET_LOCKED ? '' : '<button class="x-btn" data-x>✕</button>'}</div>` + html; $('#sheet').querySelector('[data-home]').onclick = goHome; const xb = $('#sheet').querySelector('[data-x]'); if (xb) xb.onclick = closeSheet; $('#modal').classList.remove('hidden'); $('#modal').onclick = e => { if (e.target.id === 'modal' && onClose !== false) closeSheet(); }; }
function closeSheet() { $('#modal').classList.add('hidden'); $('#sheet').innerHTML = ''; }
let toastT; function toast(t, ms = 1800) { const el = $('#toast'); el.textContent = t; el.classList.add('on'); clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove('on'), ms); }
function show(id) { for (const s of ['login', 'app', 'trip', 'admin', 'parent']) $('#' + s).classList.toggle('hidden', s !== id); window.scrollTo(0, 0); }

/* ---------- PIN / код ---------- */
function codePad(title, sub, { min = 4, max = 4, onSubmit }) {
  let v = '';
  sheet(`<h2>${title}</h2><div class="muted">${sub}</div><div class="dots" id="dots"></div><div class="err" id="perr"></div>
    <div class="pad">${[1,2,3,4,5,6,7,8,9].map(n => `<button data-k="${n}">${n}</button>`).join('')}<button data-k="del">⌫</button><button data-k="0">0</button><button data-k="ok">${max > min ? 'OK' : '✓'}</button></div>`);
  const draw = () => $('#dots').innerHTML = Array.from({ length: Math.max(max === min ? max : Math.max(v.length, min)) }, (_, i) => `<i class="${i < v.length ? 'f' : ''}"></i>`).join('');
  draw();
  const go = async () => { if (v.length < min) return; const ok = await onSubmit(v, m => { $('#perr').textContent = m; v = ''; draw(); }); };
  $('#sheet').querySelectorAll('.pad button').forEach(b => b.onclick = () => {
    const k = b.dataset.k;
    if (k === 'del') v = v.slice(0, -1); else if (k === 'ok') return go(); else if (v.length < max) v += k;
    draw(); if (max === min && v.length === max) go();
  });
}

/* ---------- вход ---------- */
const isTest = id => String(id || '').startsWith('ztest');
async function loadPub() { const s = await rpc('zhol_public_state', LS.get('zhol_test', false) ? { test: true } : {}); PUB = s; LS.set('zhol_pub', s); return s; }
function renderKids() {
  if (!PUB) { $('#kids').innerHTML = '<div class="muted" style="color:#fff">Загрузка…</div>'; return; }
  $('#kids').innerHTML = PUB.players.filter(p => !isTest(p.id)).map(p => `<button class="kid" data-id="${p.id}"><div class="av" style="background:${p.color}22">${p.avatar}</div><b>${esc(p.name)}</b><small>${p.age} лет · ${esc(p.school)}</small><br><span class="where">${p.trip ? '🛣️ в пути' : '📍 ' + esc(nname(p.location))}</span></button>`).join('');
  $('#kids').querySelectorAll('.kid').forEach(b => b.onclick = () => {
    const p = PUB.players.find(x => x.id === b.dataset.id);
    codePad(`${p.avatar} Сәлем, ${esc(p.name)}!`, 'Введи свой код из 4 цифр', { onSubmit: async (code, fail) => {
      try { const r = await rpc('zhol_login', { p: p.id, code }); if (!r.ok) return fail(errText(r.error)); SESSION = { id: p.id, code }; LS.set('zhol_mode', 'kid'); LS.set('zhol_me', SESSION); ME = r.me; REQS = r.requests; closeSheet(); enterApp(); }
      catch (e) { fail(e.offline ? 'Нет сети' : e.message); }
    } });
  });
}
async function boot() {
  renderKids();
  if (LS.get('zhol_mode', '') === 'family' && FAM) {
    try { const r = await rpc('zhol_family_login', { f: FAM.id, code: FAM.code }); if (r.ok) return enterFamily(r); LS.del('zhol_fam'); FAM = null; }
    catch (e) { const c = LS.get('zhol_famdata', null); if (c) return enterFamily(c); }
  }
  try { await loadPub(); } catch (e) {}
  renderKids();
  if (SESSION) {
    try { const r = await rpc('zhol_login', { p: SESSION.id, code: SESSION.code }); if (r.ok) { ME = r.me; REQS = r.requests; return enterApp(); } LS.del('zhol_me'); SESSION = null; }
    catch (e) { if (e.offline && PUB) { ME = PUB.players.find(p => p.id === SESSION.id); if (ME) return enterApp(); } }
  }
  show('login');
}
$('#toParent').onclick = () => codePad('Администратор', 'Введите PIN (по умолчанию 0000 — смените его)', { min: 4, max: 8, onSubmit: async (pin, fail) => {
  try { const r = await rpc('zhol_admin', { pin, action: 'overview', payload: {} }); if (!r.ok) return fail(errText(r.error)); PIN = pin; ADMIN = r; closeSheet(); show('admin'); renderAdmin(); setTimeout(() => chatTick(), 300); }
  catch (e) { fail(e.offline ? 'Нет сети' : e.message); }
} });
$('#logout').onclick = () => { if (!confirm('Выйти? На этом устройстве нужно будет снова ввести код.')) return; if (isTest(SESSION?.id)) { LS.del('zhol_test'); loadPub().then(renderKids).catch(() => {}); } LS.del('zhol_me'); SESSION = null; ME = null; chatClose(); chatBadge(0); show('login'); renderKids(); };

/* ---------- приложение ---------- */
let pollT;
function enterApp() { show('app'); renderApp(); setTimeout(() => chatTick(), 300); clearInterval(pollT); pollT = setInterval(() => { if (!$('#app').classList.contains('hidden')) refresh(); }, 30000); }
async function refresh() {
  try { await loadPub(); const r = await rpc('zhol_login', { p: SESSION.id, code: SESSION.code }); if (r.ok) { ME = r.me; REQS = r.requests; } } catch (e) {}
  renderApp();
}
function renderApp() {
  if (!ME) return;
  $('#meChip').innerHTML = `<div class="av" style="background:${ME.color}">${ME.avatar}</div><div><b>Сәлем, ${esc(ME.name)}!</b><small>${Z.LEAGUES[ME.league].name} · ${ME.trip ? 'в пути' : '📍 ' + esc(nname(ME.location))}</small></div>`;
  $('#tok').textContent = ME.tokens; $('#tix').textContent = ME.tickets;
  mapZoomInit(); renderMap(); renderMapPanel(); renderFamily(); renderAch(); renderBank(); renderDeeds(); unlockCheer();
}
$('#tabs').querySelectorAll('button').forEach(b => b.onclick = () => setTab(b.dataset.tab));
$('#homeBtn').onclick = goHome; $('#adminHome').onclick = goHome; $('#famHome').onclick = () => { closeSheet(); window.scrollTo(0, 0); };

/* ---------- карта ---------- */
function renderMap(svg = $('#map'), focusTrip = ME?.trip, doneOverride) {
  if (!PUB) return;
  const X = Z.XY, M = Z.MAP, kid = svg.id === 'map' && ME; let s = '';
  // для карты родителей «закрыт» = закрыт для всех детей
  const open = kid ? (id => isOpen(id)) : (id => !regOf(id) || PUB.players.some(p => isOpen(id, p)));
  const nodeList = PUB.nodes.filter(n => X[n.id]);
  svg.setAttribute('viewBox', `0 0 ${M.W} ${M.H}`);
  s += `<path class="land" d="${M.KAZ}"/><path class="kgz" d="${M.KGZ}"/><path class="lake" d="${M.BALKHASH}"/><path class="lake" d="${M.ARAL}"/>`;
  s += `<text class="geo-lbl" x="742" y="352">оз. Балхаш</text><text class="geo-lbl" x="318" y="372">Арал</text><text class="geo-lbl" x="14" y="470">Каспий</text><text class="geo-lbl" x="760" y="500">Кыргызстан</text>`;
  s += `<text class="map-note" x="14" y="${M.H - 8}">Схема · км — реальные дороги · 🔒 открываются добрыми делами ⭐</text>`;
  const here = kid && !ME.trip ? ME.location : null;
  for (const e of PUB.edges.filter(e => e.mode === 'air' && X[e.a] && X[e.b])) {
    const on = focusTrip?.transport === 'plane' ? false : here && (e.a === here || e.b === here) && open(e.a) && open(e.b) && nodes()[e.a]?.airport && nodes()[e.b]?.airport;
    if (!on) continue;
    const a = X[e.a], b = X[e.b], mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2 - Math.abs(a[0] - b[0]) * 0.12 - 20;
    s += `<path class="air" d="M${a} Q${mx},${my} ${b}"/>`;
  }
  const roads = PUB.edges.filter(e => e.mode === 'road' && X[e.a] && X[e.b]);
  for (const e of roads) { const lk = !open(e.a) || !open(e.b); s += `<line class="road${lk ? ' lk' : ''}" x1="${X[e.a][0]}" y1="${X[e.a][1]}" x2="${X[e.b][0]}" y2="${X[e.b][1]}"/>`; }
  for (const e of roads) {
    const lk = !open(e.a) || !open(e.b), a = X[e.a], b = X[e.b];
    if (!lk) s += `<line class="road-in" x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}"/>`;
    if (Math.hypot(a[0] - b[0], a[1] - b[1]) > 44) s += `<text class="km-lbl${lk ? ' lk' : ''}" x="${(a[0] + b[0]) / 2 + 3}" y="${(a[1] + b[1]) / 2 - 3}">${e.km}</text>`;
  }
  if (focusTrip) {
    const pts = focusTrip.path.map(n => X[n]).filter(Boolean);
    if (focusTrip.transport === 'plane') { const a = pts[0], b = pts[1]; s += `<path class="route-hl" stroke-dasharray="6 6" d="M${a} L${b}"/>`; }
    else s += `<polyline class="route-hl" points="${pts.join(' ')}"/>`;
  }
  for (const n of nodeList) {
    const [x, y] = X[n.id]; const home = n.id === 'KOR', lk = !open(n.id);
    const [lx, ly, anchor] = Z.LBL[n.id] || [9, 4, 'start'];
    s += `<g class="node ${n.kind}${lk ? ' locked' : ''}" data-node="${n.id}"><circle cx="${x}" cy="${y}" r="${home ? 11 : n.kind === 'city' ? 7 : 5}"/>${home ? `<text x="${x}" y="${y + 5}" text-anchor="middle" font-size="12">🏡</text>` : ''}${lk ? `<text class="lock" x="${x}" y="${y + 3.5}" text-anchor="middle">🔒</text>` : ''}<text x="${x + (home ? 0 : lx)}" y="${home ? y + 27 : y + ly}" text-anchor="${home ? 'middle' : anchor}">${esc(n.name)}${home ? ' · Ата и Әже' : ''}${n.airport && !lk ? ' ✈' : ''}</text><circle class="hit" cx="${x}" cy="${y}" r="16"/></g>`;
  }
  // игроки
  const groups = {};
  for (const p of PUB.players) {
    const pp = ME && p.id === ME.id ? ME : p;
    const pos = pp.trip ? tripPos(pp.trip, p.id === ME?.id ? doneOverride : undefined) : X[pp.location];
    if (!pos) continue;
    const key = pos.map(v => Math.round(v)).join(','); (groups[key] ||= { pos, list: [] }).list.push(pp);
  }
  let mePos = null;
  for (const k in groups) {
    const g = groups[k];
    g.list.forEach((p, i) => {
      const me = ME && p.id === ME.id, r = me ? 12 : 9, dx = (i - (g.list.length - 1) / 2) * 15, x = g.pos[0] + dx, y = g.pos[1] - 20;
      if (me) mePos = [x, y];
      s += `<g class="pin"><circle cx="${x}" cy="${y}" r="${r}" fill="${p.color}" stroke="#fff" stroke-width="${me ? 3 : 2}"/><text x="${x}" y="${y + (me ? 5 : 4)}" text-anchor="middle" style="font-size:${me ? 14 : 11}px">${p.avatar}</text></g>`;
    });
  }
  svg.innerHTML = s;
  if (kid) svg.querySelectorAll('[data-node]').forEach(g => g.onclick = () => nodeTap(g.dataset.node));
  mapFocus(svg, mePos || (ME && X[ME.location]));
}
// на телефоне карта крупнее и прокручивается; центрируем на себе
function mapFocus(svg, pos) {
  const w = svg.parentElement; if (!w || !pos || !w.classList.contains('zoom')) return;
  if (w.dataset.focused === (ME?.id || '') + (ME?.location || '')) return;
  requestAnimationFrame(() => { const sw = svg.getBoundingClientRect().width; if (!sw) return; const k = sw / Z.MAP.W; w.scrollLeft = pos[0] * k - w.clientWidth / 2; w.scrollTop = pos[1] * k - w.clientHeight / 2; w.dataset.focused = (ME?.id || '') + (ME?.location || ''); });
}
function mapZoomInit() {
  for (const id of ['map', 'pmap']) {
    const svg = $('#' + id); if (!svg) continue; const w = svg.parentElement;
    if (w.dataset.zinit) continue; w.dataset.zinit = 1;
    if (window.innerWidth < 900) w.classList.add('zoom');
    const b = document.createElement('button'); b.className = 'zoom-btn'; b.type = 'button';
    const lbl = () => b.textContent = w.classList.contains('zoom') ? '🗺️ Весь Казахстан' : '🔍 Крупнее';
    lbl(); b.onclick = () => { w.classList.toggle('zoom'); delete w.dataset.focused; lbl(); renderMap(svg, svg.id === 'map' ? ME?.trip : null); };
    w.parentElement.insertBefore(b, w.nextSibling);
  }
}
function nodeTap(id) {
  if (!ME) return;
  if (!isOpen(id)) return openLocked(regOf(id));
  const n = nodes()[id];
  if (id === ME.location && !ME.trip) return toast('📍 Ты здесь: ' + n.name);
  if (ME.trip) return toast(`${n.name}${n.souvenir ? ' · сувенир: ' + n.souvenir : ''}`, 2500);
  if (shortest(ME.location, id)) openTransport(id); else toast('Сюда пока не доехать по открытым дорогам');
}
function openLocked(rid) {
  const R = regInfo(rid), need = +R.need || 0, have = +ME?.stars || 0, left = Math.max(0, need - have);
  sheet(`<h2>🔒 ${R.e || ''} ${esc(R.n)}</h2><div class="muted">Города края: ${regCities(rid).map(n => '<b>' + esc(n.name) + '</b>').join(', ')}</div>
    <div class="lockbox"><div style="font-size:30px">⭐ ${have} / ${need}</div><div class="bar"><i style="width:${Math.min(100, need ? 100 * have / need : 100)}%"></i></div><div class="muted">${left ? `Нужно ещё <b>${left} ⭐</b> добрых дел. Звёзды дают хорошие оценки, прочитанные книги, помощь дома и добрые дела для людей — после подтверждения родителей.` : 'Звёзд хватает — край откроется после ближайшего подтверждения.'}</div></div>
    <button class="big-btn" id="toDeeds">⭐ Отметить доброе дело</button>`);
  $('#toDeeds').onclick = () => { closeSheet(); setTab('deeds'); };
}
function renderMapPanel() {
  const cfg = PUB.config, t = ME.trip; let h = racePanel();
  if (t) {
    const pct = Math.min(100, 100 * t.done / t.total), T = Z.TRANSPORT[t.transport];
    const org = t.origin || t.path[0], atStop = !t.challenge && interStops(t).find(s => (t.collected || []).includes(s.n) && Math.abs(s.at - t.done) < 0.05);
    h += `<h3>${T.icon} В пути: ${esc(nname(org))} → ${esc(nname(t.path.at(-1)))}</h3>${org !== t.path[0] ? `<div class="muted">сейчас ${T.icon} из ${esc(genName(t.path[0]))}</div>` : ''}<div class="bar"><i style="width:${pct}%"></i></div><div class="muted">${fmt(t.done)} из ${fmt(t.total)} км · ${T.name}</div>
      <button class="big-btn teal" id="contBtn">Продолжить поездку ▶</button>${atStop ? `<button class="big-btn" style="margin-top:10px" id="swBtn">🔄 Сменить транспорт в ${esc(locName(atStop.n))}</button>` : ''}<button class="btn" style="margin-top:10px;width:100%" id="newBtn">Выбрать другой маршрут</button>`;
  } else {
    h += `<h3>📍 Ты в: ${esc(nname(ME.location))}${ME.location === 'KOR' ? ' — у Ата и Әже 🏡' : ''}</h3><div class="muted">Куда поедем? К Ата и Әже в Кордай или в гости к брату/сестре.</div><button class="big-btn" id="newBtn">В путь! 🛣️</button>`;
  }
  h += `<div class="stats"><div class="stat"><b>${fmt(ME.today_km)}</b><small>км сегодня</small></div><div class="stat"><b>${ME.today_tokens}/${cfg.daily_token_cap}</b><small>🪙 за день</small></div><div class="stat"><b>${fmt(ME.km_total)}</b><small>км всего</small></div></div>`;
  h += `<div class="muted" style="margin-top:10px">🎫 Билет на самолёт — за каждые ${cfg.ticket_every_km} км по земле (осталось ${fmt(cfg.ticket_every_km - ME.ticket_km)} км). 🎁 В сумке: ${ME.gifts.length ? ME.gifts.map(g => esc(nodes()[g]?.souvenir)).join(', ') : 'пусто'}.</div>`;
  const kt = PUB.family.kordai_today || [];
  h += `<div class="muted" style="margin-top:8px">🏡 Сегодня у Ата и Әже: ${kt.length ? kt.map(id => PUB.players.find(p => p.id === id)?.avatar).join(' ') : 'пока никто не доехал'}</div>`;
  $('#mapPanel').innerHTML = h;
  $('#newBtn').onclick = () => openPlan();
  if ($('#contBtn')) $('#contBtn').onclick = () => openTrip();
  if ($('#swBtn')) $('#swBtn').onclick = () => openTrip();
  bindRace();
}

/* ---------- выбор маршрута ---------- */
function openPlan(force) {
  if (!force && ME.trip?.challenge && (PUB.challenges || []).some(c => c.id === +ME.trip.challenge && !c.winner)) { if (!confirm('Ты в жарысе! Если сменишь маршрут — засчитается поражение. Точно?')) return; }
  const here = ME.location, homes = {};
  for (const p of PUB.players) if (p.id !== ME.id) (homes[p.home] ||= []).push(p);
  const list = PUB.nodes.filter(n => n.id !== here && isOpen(n.id)).map(n => ({ n, r: shortest(here, n.id) })).filter(x => x.r)
    .sort((a, b) => (b.n.id === 'KOR') - (a.n.id === 'KOR') || (!!homes[b.n.id]) - (!!homes[a.n.id]) || a.r.km - b.r.km);
  const locked = REGS().filter(R => !(ME.unlocked || []).includes(R.id) && regCities(R.id).length);
  sheet(`<h2>Куда едем?</h2><div class="muted">Отсюда: ${esc(nname(here))}${ME.trip ? ' · ⚠️ текущая поездка будет заменена (км уже засчитаны)' : ''}</div>${+ME.today_km >= +PUB.config.daily_km_cap ? `<div class="capnote">На сегодня лимит ${fmt(PUB.config.daily_km_cap)} км пройден, продолжим завтра 🌙 Маршрут выбрать можно, а ехать — завтра.</div>` : ''}` + list.map(({ n, r }) => {
    const who = homes[n.id]?.map(p => p.avatar + ' ' + esc(p.name)).join(', ');
    return `<button class="opt" data-to="${n.id}"><span class="i">${n.id === 'KOR' ? '🏡' : n.kind === 'city' ? '🏙️' : '🏘️'}</span><span><b>${esc(n.name)}${n.id === 'KOR' ? ' — к Ата и Әже' : ''}</b><small>${fmt(r.km)} км по дороге${who ? ' · в гости к: ' + who : ''}${n.souvenir ? ' · сувенир: ' + esc(n.souvenir) : ''}</small></span></button>`;
  }).join('') + (locked.length ? `<h3 style="margin:16px 0 4px">🔒 Закрытые края</h3><div class="muted">Открываются звёздами ⭐ за добрые дела в жизни.</div>` + locked.map(R => `<button class="opt off-lock" data-lock="${R.id}"><span class="i">🔒</span><span><b>${R.e || ''} ${esc(R.n)}</b><small>${regCities(R.id).map(n => esc(n.name)).join(', ')} · нужно ${R.need} ⭐ (у тебя ${ME.stars || 0})</small></span></button>`).join('') : '') + `<button class="btn" style="width:100%;margin-top:12px" onclick="document.getElementById('modal').click()">Отмена</button>`);
  $('#sheet').querySelectorAll('[data-to]').forEach(b => b.onclick = () => openTransport(b.dataset.to));
  $('#sheet').querySelectorAll('[data-lock]').forEach(b => b.onclick = () => openLocked(b.dataset.lock));
}
function openTransport(to) {
  const here = ME.location, r = shortest(here, to), m = mult(ME.age);
  const rows = trRows(here, to, r);
  sheet(`<h2>${esc(nname(here))} → ${esc(nname(to))}</h2><div class="muted">Маршрут: ${r.path.map(nname).map(esc).join(' → ')}. ${m > 1 ? `Тебе нужно меньше тапов (×${m}), а км для семьи считаются честно.` : ''}</div>${rows}
    <button class="btn" style="width:100%;margin-top:12px" id="backPlan">← Назад</button>`);
  $('#backPlan').onclick = openPlan;
  $('#sheet').querySelectorAll('[data-tr]').forEach(b => b.onclick = async () => {
    const tr = b.dataset.tr, path = tr === 'plane' ? [here, to] : r.path;
    b.disabled = true;
    try { const res = await rpc('zhol_start_trip', { p: SESSION.id, code: SESSION.code, transport: tr, path }); if (!res.ok) { toast(errText(res.error)); b.disabled = false; return; } ME = res.me; closeSheet(); renderApp(); openTrip(); }
    catch (e) { toast(e.offline ? 'Нет сети — начать поездку можно только онлайн' : e.message); b.disabled = false; }
  });
}

/* ---------- поездка ---------- */
let T = null;
const FUEL_KEY = () => 'zhol_fuel_' + ME.id;
function getFuel() { const f = LS.get(FUEL_KEY(), { v: 100, t: Date.now() }); return Math.min(100, f.v + (Date.now() - f.t) / 30000); }
function setFuel(v) { LS.set(FUEL_KEY(), { v: Math.max(0, Math.min(100, v)), t: Date.now() }); }

function openTrip() {
  const trip = ME.trip; if (!trip) return;
  const TR = Z.TRANSPORT[trip.transport];
  const pend = LS.get('zhol_pend_' + ME.id, null);
  T = { trip, tr: trip.transport, TR, m: TR.noAge ? 1 : mult(ME.age), server: +trip.done, pendKm: pend?.km || 0, pendTaps: pend?.taps || 0, inflight: 0,
    lastFlush: performance.now() - (pend ? Math.min(pend.dur || 0, 60000) : 0), taps: [], intervals: [], blockedUntil: 0, paused: false, active: 0, lastProg: 0,
    nextEvent: rnd(35, 60), stamina: 100, tired: false, fuel: ME.fuel != null ? +ME.fuel : getFuel(), lastSide: null, beatT0: performance.now(), lastBeat: -1, streak: 0, holding: false, timers: [], keys: [] };
  LS.del('zhol_pend_' + ME.id);
  show('trip');
  $('#tripTitle').textContent = `${TR.icon} ${nname(trip.origin || trip.path[0])} → ${nname(trip.path.at(-1))}`;
  T.inter = trip.challenge ? [] : interStops(trip); { const d0 = localDone(); T.acked = new Set(T.inter.filter(s => s.at < d0 - 0.05).map(s => s.n)); }
  $('#tripTok').textContent = ME.tokens;
  T.empty = T.tr === 'car' && T.fuel < 1;
  buildEngine(); drawTrip(); enStart();
  T.timers.push(setInterval(flush, 2500), setInterval(tick, 100));
  if (trip.challenge) { T.timers.push(setInterval(racePoll, 4000)); racePoll(); }
  const ns = nextStop(); if (ns && localDone() >= ns.at - 0.01) stopPrompt(ns);
}
function closeTrip(toApp = true) {
  if (!T) return;
  T.timers.forEach(clearInterval); T.keys.forEach(([ev, fn]) => window.removeEventListener(ev, fn));
  const left = { km: T.pendKm, taps: T.pendTaps, dur: performance.now() - T.lastFlush };
  if (T.pendKm > 0) { LS.set('zhol_pend_' + ME.id, left); flushNow(); }
  if (T.tr === 'car') setFuel(T.fuel);
  T = null; closeSheet(); enStop();
  if (toApp) { show('app'); renderApp(); }
}
async function flushNow() {
  // финальная отправка при выходе
  const pend = LS.get('zhol_pend_' + ME.id, null); if (!pend) return;
  try { const r = await rpc('zhol_progress', { p: SESSION.id, code: SESSION.code, km: +pend.km.toFixed(3), taps: pend.taps, dur_ms: Math.round(Math.min(pend.dur, 60000)) }); if (r.me) { ME = r.me; LS.del('zhol_pend_' + ME.id); renderApp(); } }
  catch (e) {}
}
$('#tripExit').onclick = goHome;
const isAuto = tr => tr === 'bus' || tr === 'train' || tr === 'plane';
const capLeft = () => Math.max(0, (+PUB.config.daily_km_cap || 2500) - (+ME.today_km || 0) - T.inflight - T.pendKm);
const localDone = () => Math.min(T.trip.total, T.server + T.inflight + T.pendKm);

function addKm(km, isTap) {
  if (!T || T.paused || T.arriving) return false;
  const now = performance.now();
  if (now < T.blockedUntil) { toast('Пауза: похоже на автокликер 🤖'); return false; }
  if (isTap) {
    T.taps = T.taps.filter(t => now - t < 1000);
    if (T.taps.length >= 12) { toast('Не так быстро! Макс. 12 тапов в секунду'); return false; }
    if (T.taps.length) T.intervals.push(now - T.taps.at(-1));
    T.taps.push(now);
    if (T.intervals.length > 30) T.intervals.shift();
    if (T.tr !== 'horse' && T.intervals.length >= 30) {
      const mean = T.intervals.reduce((a, b) => a + b, 0) / T.intervals.length;
      const sd = Math.sqrt(T.intervals.reduce((a, b) => a + (b - mean) ** 2, 0) / T.intervals.length);
      if (mean < 300 && sd < 4) { T.blockedUntil = now + 15000; T.intervals = []; toast('Слишком ровные тапы — похоже на автокликер. Пауза 15 сек', 3000); return false; }
    }
    T.pendTaps++;
  }
  const ns = nextStop(), lim = ns ? Math.min(T.trip.total, ns.at + 0.002) : T.trip.total;
  const left = capLeft();
  if (left <= 0.001) { if (!T.capped) { T.capped = true; T.holding = false; toast(`🌙 На сегодня лимит ${fmt(PUB.config.daily_km_cap)} км пройден, продолжим завтра 🌙`, 4000); drawTrip(); } return false; }
  const room = Math.min(lim - localDone(), left);
  T.pendKm += Math.max(0, Math.min(km, room));
  T.lastProg = now;
  if (ns && localDone() >= ns.at - 1e-6 && localDone() < T.trip.total - 1e-6) { flush(); drawTrip(); stopPrompt(ns); return true; }
  if (localDone() >= T.trip.total - 1e-6) { T.arriving = true; flush(); }
  drawTrip();
  return true;
}
const nextStop = () => T && T.inter ? T.inter.find(s => !T.acked.has(s.n)) : null;
function stopPrompt(s) {
  if (!T) return; T.paused = true; T.holding = false;
  const TR = T.TR, dest = T.trip.path.at(-1);
  sheet(`<div style="text-align:center"><div style="font-size:56px">📍</div><h2>Ты в ${esc(locName(s.n))}!</h2><p>Продолжить ${TR.on} ${TR.icon} или сменить транспорт? До ${esc(genName(dest))} осталось ${fmt(T.trip.total - s.at)} км.</p>
    <button class="big-btn teal" id="stCont">Продолжить ${TR.icon}</button><button class="big-btn" style="margin-top:10px" id="stSw">Сменить транспорт 🔄</button></div>`, false);
  $('#stCont').onclick = () => { if (!T) return; T.acked.add(s.n); T.paused = false; closeSheet(); drawTrip(); };
  $('#stSw').onclick = () => openSwitch(s);
}
async function settle() {
  for (let k = 0; k < 60 && T && (T.busy || T.pendKm > 0); k++) { if (!T.busy) await flush(); else await new Promise(r => setTimeout(r, 100)); }
}
function openSwitch(s) {
  if (!T) return;
  const dest = T.trip.path.at(-1), path = T.trip.path.slice(s.i), km = T.trip.legs.slice(s.i).reduce((x, y) => x + +y, 0);
  sheet(`<h2>🔄 ${esc(nname(s.n))} → ${esc(nname(dest))}</h2><div class="muted">Дальше: ${path.map(nname).map(esc).join(' → ')}. Километры до ${esc(genName(s.n))} уже засчитаны.</div>${trRows(s.n, dest, { path, km }, T.tr)}
    <button class="btn" style="width:100%;margin-top:12px" id="swBack">← Назад</button>`, false);
  $('#swBack').onclick = () => stopPrompt(s);
  $('#sheet').querySelectorAll('[data-tr]').forEach(b => b.onclick = async () => {
    const tr = b.dataset.tr; $('#sheet').querySelectorAll('[data-tr]').forEach(x => x.disabled = true);
    try {
      await settle(); if (!T) return;
      if (!(ME.trip?.collected || []).includes(s.n)) { toast('Ещё чуть-чуть до ' + genName(s.n) + '…'); T.paused = false; closeSheet(); return; }
      const res = await rpc('zhol_switch_transport', { p: SESSION.id, code: SESSION.code, transport: tr });
      if (!res.ok) { toast(errText(res.error)); return openSwitch(s); }
      ME = res.me; closeTrip(false); toast(`Пересадка в ${locName(s.n)}: ${Z.TRANSPORT[tr].icon} ${Z.TRANSPORT[tr].name}`); openTrip();
    } catch (e) { toast(e.offline ? 'Нет сети — пересадка только онлайн' : e.message); if (T) openSwitch(s); }
  });
}
async function flush() {
  if (!T || T.busy) return;
  if (T.pendKm <= 0 && T.pendTaps <= 0) { if (T.arriving && T.inflight === 0) T.arriving = false; return; }
  T.busy = true;
  const km = T.pendKm, taps = T.pendTaps, dur = Math.min(60000, performance.now() - T.lastFlush);
  T.inflight = km; T.pendKm = 0; T.pendTaps = 0; T.lastFlush = performance.now();
  try {
    const r = await rpc('zhol_progress', { p: SESSION.id, code: SESSION.code, km: +km.toFixed(3), taps, dur_ms: Math.round(dur) });
    T && (T.inflight = 0);
    if (r.me) ME = r.me;
    if (!T) return;
    if (!r.ok) { toast(errText(r.error)); if (r.error === 'no_trip') return closeTrip(true); }
    const before = T.server;
    T.server = ME.trip ? +ME.trip.done : T.trip.total;
    // авто-транспорт: если сервер засчитал меньше из-за задержки сети, недосчитанное отправим ещё раз (сервер всё равно проверит темп)
    const lost = km - (T.server - before);
    if (r.ok && isAuto(T.tr) && ME.trip && lost > 0.001 && capLeft() > 0.001) T.pendKm += Math.min(lost, capLeft());
    if (T.capped && capLeft() > 0.001) T.capped = false;
    if (T.tr === 'car' && ME.fuel != null && +ME.fuel < T.fuel - 1) T.fuel = +ME.fuel;
    $('#tripTok').textContent = ME.tokens;
    for (const ev of r.events || []) {
      if (ev.type === 'new_city') toast(`Новый город: ${nname(ev.node)}! +${ev.tokens} 🪙`);
      if (ev.type === 'souvenir') toast(`🎁 Сувенир: ${nodes()[ev.node]?.souvenir}`);
      if (ev.type === 'ticket') toast('🎫 Ты заработал билет на самолёт!');
    }
    if (r.arrived) return arrival(r.events || []);
    T.arriving = false;
  } catch (e) {
    if (T) { T.pendKm += km; T.pendTaps += taps; T.inflight = 0; T.lastFlush -= dur; LS.set('zhol_pend_' + ME.id, { km: T.pendKm, taps: T.pendTaps, dur: Math.min(60000, performance.now() - T.lastFlush) }); }
  } finally { if (T) T.busy = false; drawTrip(); }
}
function arrival(events) {
  const to = T.trip.path.at(-1), tr = T.tr;
  const before = new Set(T.achBefore || []);
  T.timers.forEach(clearInterval); T.keys.forEach(([ev, fn]) => window.removeEventListener(ev, fn));
  if (tr === 'car') setFuel(T.fuel);
  T = null; LS.del('zhol_pend_' + ME.id); enStop();
  const del = events.filter(e => e.type === 'delivered'), cities = events.filter(e => e.type === 'new_city');
  const rw = events.find(e => e.type === 'race_win'), rl = events.find(e => e.type === 'race_lose'), rf = events.find(e => e.type === 'race_forfeit_win');
  const raceHtml = rw ? `<p style="font-size:20px">🏆 <b>Победа в жарысе!</b> Ты обогнал(а) ${pl(rw.vs).avatar} ${esc(pl(rw.vs).name)}${rw.tokens ? ' · +' + rw.tokens + ' 🪙' : ''}</p>` : rl ? `<p>⚔️ ${pl(rl.winner).avatar} ${esc(pl(rl.winner).name)} финишировал(а) первым. Ты молодец, что доехал(а)!${rl.tokens ? ' +' + rl.tokens + ' 🪙 за участие' : ''}</p>` : rf ? `<p>🏆 Соперник сошёл с дистанции — победа в жарысе за тобой!</p>` : '';
  const host = PUB.players.filter(p => p.home === to && p.id !== ME.id);
  const title = to === 'KOR' ? 'Сәлем, Кордай! 🏡' : `Сәлем, ${nname(to)}!`;
  const text = to === 'KOR' ? 'Ата и Әже очень рады тебе! Чай уже на столе ☕' : host.length ? `Тебя встречают: ${host.map(p => p.avatar + ' ' + esc(p.name)).join(', ')}` : 'Ты доехал! Отличная дорога.';
  sheet(`<div style="text-align:center"><div style="font-size:64px">${to === 'KOR' ? '👵🏡👴' : '🎉'}</div><h2>${title}</h2><p>${text}</p>${raceHtml}
    ${cities.length ? `<p>Новые места: ${cities.map(c => esc(nname(c.node))).join(', ')}</p>` : ''}
    ${del.length ? `<p>🎁 Подарки для Әже доставлены: ${del.map(d => esc(nodes()[d.node]?.souvenir) + ' (+' + d.tokens + ' 🪙)').join(', ')}</p>` : ''}
    <p class="muted">Жетонов теперь: ${ME.tokens} 🪙</p><button class="big-btn teal" id="arrOk">Рахмет! 🙌</button></div>`, false);
  $('#arrOk').onclick = () => { closeSheet(); show('app'); refresh(); };
}
function drawTrip() {
  if (!T) return;
  const t = T.trip, total = +t.total, done = T.shown = Math.max(T.shown || 0, localDone());
  let cum = 0; const stops = t.path.map((n, i) => { if (i > 0) cum += +t.legs[i - 1]; return { n, at: cum }; });
  const pct = x => (100 * x / total).toFixed(2);
  const next = stops.find(s => s.at > done + 1e-6);
  const RT = raceTripHtml(done, total);
  $('#route').innerHTML = `<div class="line"><div class="track"></div><div class="fill" style="width:${pct(done)}%"></div>${stops.map(s => `<div class="stop ${s.at <= done ? 'done' : ''}" style="left:${pct(s.at)}%"></div>`).join('')}<div class="who" style="left:${pct(done)}%">${T.TR.icon}</div>${RT.marker}</div>
    ${T.capped ? `<div class="capnote">На сегодня лимит ${fmt(PUB.config.daily_km_cap)} км пройден, продолжим завтра 🌙<br><small>Поездка сохранена — завтра можно ехать дальше.</small></div>` : ''}<div class="names">${stops.length <= 5 ? stops.map(s => `<span>${esc(nname(s.n))}</span>`).join('') : `<span>${esc(nname(stops[0].n))}</span><span>…</span><span>${esc(nname(stops.at(-1).n))}</span>`}</div>`;
  $('#tripStats').innerHTML = `<div><b>${fmt(total - done)}</b><small>км осталось</small></div><div><b>${next ? esc(nname(next.n)) : '🏁'}</b><small>${next ? 'через ' + fmt(next.at - done) + ' км' : 'финиш'}</small></div>${RT.stat || `<div><b>${fmt(ME.today_km + T.pendKm + T.inflight)}</b><small>км сегодня</small></div>`}`;
  const meter = $('#meter'); if (meter) {
    const v = T.tr === 'car' ? T.fuel : T.stamina;
    meter.querySelector('i').style.width = v + '%'; meter.querySelector('span').textContent = T.tr === 'car' ? (T.empty ? '⛽ Бензин кончился · ' + Math.floor(v) + '%' : '⛽ Бензин ' + Math.round(v) + '%') : (T.tired ? '😮‍💨 Отдых… ' + Math.floor(v) + '% (нужно ' + REST_TO + '%)' : '💪 Силы ' + Math.round(v) + '%');
    meter.classList.toggle('low', T.tr === 'car' ? T.empty : T.tired);
  }
  if (T.tr === 'car') carUi();
}
const REST_TO = 30, FUEL_TO = 10;
function tire(x, msg) { T.stamina = Math.max(0, T.stamina - x); if (T.stamina <= 0 && !T.tired) { T.tired = true; toast(msg, 2500); } }
const tiredMsg = () => T.tr === 'horse' ? 'Ат устал 🐎 Пусть отдохнёт (до ' + REST_TO + '%) или дай жем' : 'Устал… отдохни немного — силы вернутся до ' + REST_TO + '%';
const mmss = s => { s = Math.max(0, Math.ceil(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
function carUi() {
  const g = $('#gas'), e = $('#empty'); if (!g || !e) return;
  g.classList.toggle('hidden', T.empty); e.classList.toggle('hidden', !T.empty);
  if (T.empty) $('#emptyT').textContent = `Бак наполнится до ${FUEL_TO}% через ${mmss((FUEL_TO - T.fuel) * 30)} (+1% каждые 30 сек)`;
}
function key(ev, fn) { window.addEventListener(ev, fn); T.keys.push([ev, fn]); }
function buildEngine() {
  const E = $('#engine'), TR = T.TR, m = T.m; let h = `<div class="hint">${TR.hint}${T.tr === 'horse' && T.trip.path.includes('KOR') ? ' Эта дорога ведёт через Кордай — жетоны ×1.5!' : ''}</div>`;
  if (['walk', 'bike', 'horse', 'car'].includes(T.tr)) h += `<div class="meter" id="meter"><i></i><span></span></div>`;
  if (T.tr === 'walk') h += `<button class="stepbtn" id="step">👣 Шаг</button>`;
  if (T.tr === 'bike') h += `<div class="pads"><button class="pedal next" id="pl">◀ Левая</button><button class="pedal next" id="pr">Правая ▶</button></div>`;
  if (T.tr === 'horse') h += `<div class="beatwrap"><div class="beat" id="beat">🐎</div></div><div class="hint" id="combo">Лови ритм копыт: тык-тык-тык</div><div class="inline"><button class="btn" id="oats" style="display:none">🌾 Дать жем</button></div><button class="hoof" id="hoof">🐾 Цок!</button>`;
  if (T.tr === 'car') h += `<button class="gas" id="gas">⛽ Газ (держи)</button><div class="empty hidden" id="empty"><div class="et">⛽ Бензин кончился</div><div class="muted" id="emptyT"></div><button class="stepbtn" id="push">🫸 Толкать машину</button><div class="muted">Толкать — медленно, как пешком. Ещё может встретиться заправка, а в следующем городе можно пересесть на другой транспорт.</div></div>`;
  if (T.tr === 'bus' || T.tr === 'train' || T.tr === 'plane') h = `<div id="enIn" class="enslot enin"></div>` + h + `<div class="auto" id="auto"><div class="veh">${TR.icon}</div></div><div class="hint">${T.tr !== 'plane' ? 'Едем, пока окно открыто. Лови бонусы!' : 'Летим! Не закрывай окно.'}</div>`;
  E.innerHTML = h;
  const down = (el, fn) => el.addEventListener('pointerdown', e => { e.preventDefault(); fn(e); });
  if (T.tr === 'walk') {
    down($('#step'), () => { if (T.tired) return toast(tiredMsg()); if (addKm(TR.perTap * m, true)) tire(0.4, tiredMsg()); });
    key('keydown', e => { if (e.key === 'Enter' && !e.repeat) { e.preventDefault(); $('#step').dispatchEvent(new PointerEvent('pointerdown')); } });
  }
  if (T.tr === 'bike') {
    const ped = side => { if (T.lastSide === side) return toast('По очереди: левая — правая!'); if (T.tired) return toast(tiredMsg()); if (addKm(TR.perTap * m, true)) { T.lastSide = side; tire(0.5, tiredMsg()); $('#pl').classList.toggle('next', side === 'R'); $('#pr').classList.toggle('next', side === 'L'); } };
    down($('#pl'), () => ped('L')); down($('#pr'), () => ped('R'));
    key('keydown', e => { if (e.repeat) return; if (e.key === 'ArrowLeft') { e.preventDefault(); ped('L'); } if (e.key === 'ArrowRight') { e.preventDefault(); ped('R'); } });
  }
  if (T.tr === 'horse') {
    const P = 450;
    const hit = () => {
      if (T.tired) return toast(tiredMsg());
      const now = performance.now(), ph = (now - T.beatT0) % P, dist = Math.min(ph, P - ph), idx = Math.round((now - T.beatT0) / P);
      if (idx === T.lastBeat) return;
      T.lastBeat = idx;
      const on = dist <= 100;
      if (addKm((on ? TR.perTap : TR.offBeat) * m, true)) {
        tire(on ? 1.2 : 2.5, tiredMsg()); T.streak = on ? T.streak + 1 : 0;
        $('#combo').textContent = on ? (T.streak >= 8 ? `🔥 Ритм ×${T.streak}! Скачем!` : `В ритм! ×${T.streak}`) : 'Мимо ритма — медленнее';
      }
    };
    down($('#hoof'), hit);
    key('keydown', e => { if ((e.code === 'Space' || e.key === 'ArrowUp') && !e.repeat) { e.preventDefault(); hit(); } });
    $('#oats').onclick = () => { T.stamina = Math.min(100, T.stamina + 50); $('#oats').style.display = 'none'; toast('Ат доволен! Силы +50 🌾'); };
    T.timers.push(setInterval(() => { if (!T) return; const b = $('#beat'); b.classList.add('flash'); setTimeout(() => b && b.classList.remove('flash'), 120); }, P));
    T.beatT0 = performance.now();
    T.timers.push(setInterval(() => { if (!T || $('#oats').style.display !== 'none') return; if (Math.random() < 0.35) { $('#oats').style.display = ''; setTimeout(() => { const o = $('#oats'); if (o) o.style.display = 'none'; }, 8000); } }, 15000));
  }
  if (T.tr === 'car') {
    const g = $('#gas');
    const on = v => { if (!T) return; if (v && T.empty) return; T.holding = v; g.classList.toggle('on', v); };
    g.addEventListener('pointerdown', e => { e.preventDefault(); g.setPointerCapture?.(e.pointerId); on(true); });
    for (const ev of ['pointerup', 'pointercancel', 'pointerleave']) g.addEventListener(ev, () => on(false));
    down($('#push'), () => { if (!T.empty) return; addKm(0.10 * m, true); });
    key('keydown', e => { if (e.code === 'Space') { e.preventDefault(); if (T.empty) { if (!e.repeat) $('#push').dispatchEvent(new PointerEvent('pointerdown')); } else on(true); } });
    key('keyup', e => { if (e.code === 'Space') on(false); });
  }
  if (T.tr === 'bus' || T.tr === 'train') T.timers.push(setInterval(spawnBonus, 9000));
}
function spawnBonus() {
  if (!T || T.paused || !$('#auto')) return;
  const b = document.createElement('button'); b.className = 'bonus'; b.textContent = pick(['🍎', '🥟', '⭐', '🫖', '🎁']);
  b.style.left = rnd(8, 75) + '%'; b.style.top = rnd(8, 65) + '%';
  b.onclick = async () => { b.remove(); try { const r = await rpc('zhol_bonus', { p: SESSION.id, code: SESSION.code, kind: 'bus' }); if (r.me) ME = r.me; toast(r.tokens ? `+${r.tokens} 🪙` : 'Бонусы на сегодня закончились'); $('#tripTok') && ($('#tripTok').textContent = ME.tokens); } catch (e) {} };
  $('#auto').appendChild(b); setTimeout(() => b.remove(), 3500);
}
let lastTick = performance.now();
function tick() {
  if (!T) return;
  const now = performance.now(), dt = Math.min(0.5, (now - lastTick) / 1000); lastTick = now;
  if (document.hidden || T.paused) return;
  const TR = T.TR;
  if (T.tr === 'car') {
    if (!T.empty && T.fuel <= 0) T.empty = true;
    if (T.holding && !T.empty) { const use = Math.min(dt, T.fuel); addKm(TR.perSec * T.m * use, false); T.fuel = Math.max(0, T.fuel - dt); if (T.fuel <= 0) { T.empty = true; T.holding = false; $('#gas')?.classList.remove('on'); toast('⛽ Бензин кончился! Жди заправку или толкай машину', 3000); } }
    else T.fuel = Math.min(100, T.fuel + dt / 30);
    if (T.empty && T.fuel >= FUEL_TO) { T.empty = false; toast('⛽ В баке ' + Math.round(T.fuel) + '% — можно ехать!'); }
    drawTrip();
  } else if (T.tr === 'bus' || T.tr === 'train' || T.tr === 'plane') addKm(TR.perSec * dt, false);
  else { if (now - T.lastProg > 1200) T.stamina = Math.min(100, T.stamina + dt * (T.tr === 'horse' ? 6 : 10)); if (T.tired && T.stamina >= REST_TO) { T.tired = false; toast('💪 Отдохнул — вперёд!'); } drawTrip(); }
  if (now - T.lastProg < 2000 && T.tr !== 'plane') { T.active += dt; if (T.active >= T.nextEvent) { if (T.en?.quiz && !T.en.quiz.res) T.active -= 8; else { T.active = 0; T.nextEvent = rnd(40, 70); miniEvent(); } } }
}

/* ---------- 📘 English / 🇰🇿 Қазақша в дороге ---------- */
// Карточки слов в пустом месте экрана поездки (у «ручного» транспорта — компактно над кнопками, у автобуса/поезда/самолёта — крупно в окне).
// Язык у каждого ребёнка (ME.en.lang): en — английский по возрасту (A1/A2/B1), kk — казахский (базовый, школьная программа 9–11 лет), both — по очереди.
// Каждые ~5 карточек (не чаще 40 сек) или ~75 сек — мини-тест: вопрос и проверку делает сервер (zhol_en_quiz / zhol_en_answer), верно — +1 🪙 (до 10 в день).
// Интервальное повторение: слова с ошибкой (localStorage) возвращаются чаще, пока на них не ответят верно 2 раза.
const EN_LVL = { a1: { n: 'A1 · начальный', ex: false }, a2: { n: 'A2 · базовый', ex: true }, b1: { n: 'B1 · средний', ex: true } };
const LANGS = { en: '📘 English', kk: '🇰🇿 Қазақша', both: '🇰🇿 + 📘 Обе' };
const enLvl = age => age <= 11 ? 'a1' : age <= 14 ? 'a2' : 'b1';
const enWords = lvl => (window.ZHOL_WORDS?.[lvl] || []).map(w => ({ id: lvl + ':' + w[0], en: w[0], hint: w[1], ru: w[2], kk: w[3], ex: w[4], cat: w[5] }));
const kkWords = () => enWords('a1').filter(w => w.kk);
const enLang = () => ME.en?.lang || 'en';
const enOff = () => LS.get('zhol_en_off_' + ME.id, false);
const enMem = () => { const m = LS.get('zhol_en2_' + ME.id, null); return m && m.seen && m.due ? m : { seen: {}, due: {} }; };
const enSave = m => LS.set('zhol_en2_' + ME.id, m);
const canSpeak = () => 'speechSynthesis' in window && typeof SpeechSynthesisUtterance !== 'undefined';
function say(t) {
  if (!canSpeak()) return;
  try { speechSynthesis.cancel(); const vs = speechSynthesis.getVoices(), v = vs.find(v => /^en[-_](US|GB)/i.test(v.lang)) || vs.find(v => /^en/i.test(v.lang));
    const u = new SpeechSynthesisUtterance(t); if (v) u.voice = v; u.lang = v?.lang || 'en-US'; u.rate = 0.85; speechSynthesis.speak(u); } catch (e) {}
}
function enStop() { $('#enTop').innerHTML = ''; if ($('#enIn')) $('#enIn').innerHTML = ''; try { canSpeak() && speechSynthesis.cancel(); } catch (e) {} }
function enStart() {
  enStop(); if (!T || !window.ZHOL_WORDS) return;
  const lvl = ME.en?.lvl || enLvl(ME.age), big = isAuto(T.tr), lang = enLang();
  T.en = { lvl, lang, decks: { en: enWords(lvl), kk: kkWords() }, turn: lang === 'en' ? 'en' : 'kk', qturn: lang === 'en' ? 'en' : 'kk', slot: big ? '#enIn' : '#enTop', big, cur: null, recent: [], cards: 0, lastQuiz: performance.now(), lastCard: 0, quiz: null, busy: false };
  if (!T.en.decks.en.length) { T.en = null; return; }
  enNext(); T.timers.push(setInterval(enTick, 1000));
}
const enKey = (L, id) => L + '|' + id;
function enPick(L) {
  const E = T.en, m = enMem(), deck = E.decks[L], not = w => !(E.cur && E.cur.L === L && w.id === E.cur.id);
  const due = deck.filter(w => m.due[enKey(L, w.id)] && not(w));
  if (due.length && Math.random() < 0.35) return pick(due);
  const unseen = deck.filter(w => !m.seen[enKey(L, w.id)] && not(w));
  return pick(unseen.length ? unseen : deck.filter(not));
}
function enNext() {
  const E = T?.en; if (!E || E.quiz) return;
  const L = E.lang === 'both' ? E.turn : E.lang; if (E.lang === 'both') E.turn = L === 'kk' ? 'en' : 'kk';
  const w = { ...enPick(L), L }; E.cur = w; E.cards++; E.lastCard = performance.now();
  E.recent = [w, ...E.recent.filter(x => !(x.id === w.id && x.L === L))].slice(0, 10);
  const m = enMem(), k = enKey(L, w.id); m.seen[k] = (m.seen[k] || 0) + 1; enSave(m);
  enRender();
}
function enHide() { LS.set('zhol_en_off_' + ME.id, true); if (T?.en) T.en.quiz = null; enRender(); toast('Карточки скрыты. Вернуть — кнопка «📘 Слова»', 2500); }
function enRender() {
  const E = T?.en; if (!E) return;
  const el = $(E.slot);
  if (enOff()) { el.innerHTML = `<div class="enoff"><button class="enpill" id="enOn">${E.lang === 'en' ? '📘 English' : E.lang === 'kk' ? '🇰🇿 Қазақша' : '📘 Слова'}</button></div>`; $('#enOn').onclick = () => { LS.set('zhol_en_off_' + ME.id, false); E.lastCard = 0; enNext(); }; return; }
  if (E.quiz) return enQuizRender();
  const w = E.cur, kk = w.L === 'kk', ex = !kk && EN_LVL[E.lvl].ex && w.ex;
  const btns = `<span class="enbtns">${!kk && canSpeak() ? '<button id="enSay" title="Послушать" aria-label="Послушать">🔊</button>' : ''}<button id="enNx" title="Следующее слово" aria-label="Следующее слово">▶</button><button id="enX" title="Скрыть карточки" aria-label="Скрыть карточки">✕</button></span>`;
  el.innerHTML = kk
    ? `<div class="encard kk ${E.big ? 'big' : 'mini'}"><div class="enhead"><span>🇰🇿 Қазақша в дороге · базовый</span>${btns}</div>
      <div class="enword"><b>${esc(w.kk)}</b></div><div class="enru">${esc(w.ru)} <span class="enkk">· англ. ${esc(w.en)}</span></div></div>`
    : `<div class="encard ${E.big ? 'big' : 'mini'}"><div class="enhead"><span>📘 English в дороге · ${EN_LVL[E.lvl].n}</span>${btns}</div>
      <div class="enword"><b>${esc(w.en)}</b> <span class="enhint">[${esc(w.hint)}]</span></div>
      <div class="enru">${esc(w.ru)}${w.kk ? ` <span class="enkk">· қаз. ${esc(w.kk)}</span>` : ''}</div>${ex ? `<div class="enex">«${esc(w.ex)}»</div>` : ''}</div>`;
  if ($('#enSay')) $('#enSay').onclick = () => say(w.en + (ex && E.big ? '. ' + w.ex : ''));
  $('#enNx').onclick = () => enNext();
  $('#enX').onclick = enHide;
}
function enTick() {
  const E = T?.en; if (!E || T.paused || document.hidden || enOff() || E.quiz || E.busy) return;
  const now = performance.now();
  if (E.cards >= 3 && now - E.lastQuiz > 40000 && (E.cards >= 5 || now - E.lastQuiz > 75000)) return enQuiz();
  if (now - E.lastCard > (E.big ? 10000 : 15000)) enNext();
}
async function enQuiz() {
  const E = T.en; E.busy = true; E.lastQuiz = performance.now(); E.cards = 0;
  const L = E.lang === 'both' ? E.qturn : E.lang; if (E.lang === 'both') E.qturn = L === 'kk' ? 'en' : 'kk';
  const m = enMem(), due = E.decks[L].filter(w => m.due[enKey(L, w.id)]).map(w => w.id), rec = E.recent.filter(x => x.L === L).map(x => x.id);
  const w = due.length && Math.random() < 0.6 ? pick(due) : rec.length ? pick(rec) : null;
  const rev = Math.random() < (L === 'kk' ? 0.4 : E.lvl === 'a1' ? 0.3 : 0.45);
  const mode = L === 'kk' ? (rev ? 'ru2kk' : 'kk2ru') : (rev ? 'ru2en' : 'en2ru');
  try { const r = await rpc('zhol_en_quiz', { p: SESSION.id, code: SESSION.code, w, mode }); if (r.ok && T?.en === E) E.quiz = { ...r, L, picked: null, res: null }; } catch (e) {}
  E.busy = false; if (T?.en === E) { if (E.quiz) enRender(); else E.lastCard = 0; }
}
const QTITLE = { en2ru: '📘 Мини-тест · Выбери перевод', ru2en: '📘 Мини-тест · Как это по-английски?', kk2ru: '🇰🇿 Мини-тест · Выбери перевод', ru2kk: '🇰🇿 Мини-тест · Как это по-казахски?' };
function enQuizRender() {
  const E = T.en, q = E.quiz, el = $(E.slot), R = q.res;
  el.innerHTML = `<div class="encard quiz ${q.L === 'kk' ? 'kk' : ''} ${E.big ? 'big' : 'mini'}"><div class="enhead"><span>${QTITLE[q.mode]}</span><span class="enbtns"><button id="enX" title="Скрыть карточки" aria-label="Скрыть карточки">✕</button></span></div>
    <div class="enword"><b>${esc(q.prompt)}</b>${q.mode === 'en2ru' && canSpeak() ? ' <button class="ensay" id="enSay" aria-label="Послушать">🔊</button>' : ''}</div>
    <div class="enopts">${q.options.map((o, i) => `<button data-o="${i}" class="${R ? (i === R.answer ? 'ok' : i === q.picked ? 'no' : '') : ''}" ${R ? 'disabled' : ''}>${esc(o)}</button>`).join('')}</div>
    ${R ? `<div class="enres ${R.correct ? 'ok' : 'no'}">${R.correct ? (R.tokens ? `✅ ${q.L === 'kk' ? 'Дұрыс!' : 'Верно!'} +${R.tokens} 🪙` : R.limit ? '✅ Верно! Жетоны на сегодня уже получены (дневной лимит)' : '✅ Верно!') : `❌ Правильно: <b>${esc(R.answer_text)}</b> — это слово скоро вернётся`} <button class="enlink" id="enGo">Дальше ▶</button></div>` : ''}</div>`;
  if ($('#enSay')) $('#enSay').onclick = () => say(q.prompt);
  $('#enX').onclick = enHide;
  el.querySelectorAll('[data-o]').forEach(b => b.onclick = () => enAnswer(+b.dataset.o));
  if ($('#enGo')) $('#enGo').onclick = () => { E.quiz = null; enNext(); };
}
async function enAnswer(i) {
  const E = T?.en, q = E?.quiz; if (!q || q.res || E.busy) return;
  E.busy = true; q.picked = i;
  try {
    const r = await rpc('zhol_en_answer', { p: SESSION.id, code: SESSION.code, q: q.id, choice: i });
    if (!r.ok) { E.busy = false; E.quiz = null; return enNext(); }
    q.res = r; if (r.me) { ME = r.me; if ($('#tripTok')) $('#tripTok').textContent = ME.tokens; }
    const m = enMem(), k = enKey(q.L, q.word); if (r.correct) { if (m.due[k] && --m.due[k] <= 0) delete m.due[k]; } else m.due[k] = 2; enSave(m);
  } catch (e) { E.busy = false; E.quiz = null; toast(e.offline ? 'Нет сети' : 'Не получилось проверить ответ'); return enNext(); }
  E.busy = false;
  if (T?.en === E) { enRender(); setTimeout(() => { if (T?.en === E && E.quiz === q) { E.quiz = null; enNext(); } }, q.res.correct ? 4500 : 7000); }
}
function enProfileCard() {
  const en = ME.en || { ok: 0, n: 0, learned: 0, kk_learned: 0, lvl: enLvl(ME.age), lang: 'en' }, lvl = en.lvl || enLvl(ME.age), lang = en.lang || 'en';
  const cap = +(PUB?.config?.en_daily_tokens ?? 10), today = +(ME.today_counters?.en || 0);
  return `<div class="card"><h3>📘 Слова в дороге</h3><div class="muted">В поездке на свободном месте экрана появляются слова, а иногда — мини-тест. Верный ответ: +1 🪙, до ${cap} 🪙 в день. Слова с ошибкой возвращаются чаще.<br>📘 English — твой уровень ${EN_LVL[lvl].n} (${enWords(lvl).length} слов) · 🇰🇿 Қазақша — базовый уровень (${kkWords().length} слов)</div>
    <div class="inline enlangs" style="margin-top:10px">${Object.entries(LANGS).map(([k, t]) => `<button class="btn ${k === lang ? 'p' : ''}" data-lang="${k}">${t}</button>`).join('')}</div>
    <div class="stats" style="margin-top:10px">${lang !== 'kk' ? `<div class="stat"><b>${en.learned}</b><small>выучено English</small></div>` : ''}${lang !== 'en' || en.kk_learned ? `<div class="stat"><b>${en.kk_learned || 0}</b><small>выучено қазақша</small></div>` : ''}<div class="stat"><b>${en.ok} из ${en.n}</b><small>верных${en.n ? ' · ' + Math.round(100 * en.ok / en.n) + '%' : ''}</small></div><div class="stat"><b>${today}/${cap}</b><small>🪙 сегодня</small></div></div>
    <button class="btn" id="enTg" style="margin-top:10px">${enOff() ? '👀 Показывать слова в дороге' : '🙈 Не показывать слова в дороге'}</button></div>`;
}
async function enSetLang(lang) {
  try { const r = await rpc('zhol_en_lang', { p: SESSION.id, code: SESSION.code, lang }); if (!r.ok) return toast(errText(r.error)); ME = r.me; renderAch(); toast('Слова в дороге: ' + LANGS[lang]); }
  catch (e) { toast(e.offline ? 'Нет сети' : e.message); }
}
const enFamLine = k => { const en = k.en || { ok: 0, n: 0, learned: 0, kk_learned: 0, lvl: enLvl(k.age), lang: 'en' }, lang = en.lang || 'en';
  const parts = [];
  if (lang !== 'kk' || en.learned) parts.push(`📘 English: выучено ${en.learned} ${plural(en.learned, 'слово', 'слова', 'слов')} (${EN_LVL[en.lvl || enLvl(k.age)].n})`);
  if (lang !== 'en' || en.kk_learned) parts.push(`🇰🇿 Қазақша: выучено ${en.kk_learned || 0} ${plural(en.kk_learned || 0, 'слово', 'слова', 'слов')}`);
  return `<div class="kblock"><b>Слова в дороге (${LANGS[lang]}):</b> ${parts.join(' · ')} · верно ${en.ok} из ${en.n}${en.n ? ' (' + Math.round(100 * en.ok / en.n) + '%)' : ''}</div>`; };
const plural = (n, a, b, c) => { n = Math.abs(n) % 100; const d = n % 10; return n > 10 && n < 20 ? c : d === 1 ? a : d >= 2 && d <= 4 ? b : c; };

/* ---------- мини-события ---------- */
function miniEvent() {
  if (!T) return;
  const tr = T.tr, pool = ['tea', 'gift', 'quiz', 'quiz'];
  if (tr === 'bike' || tr === 'car') pool.push('flat');
  if (tr === 'car' || tr === 'bus') pool.push('jam');
  if (tr === 'horse') pool.push('oats', 'oats');
  if (tr === 'car') pool.push('fuel');
  if (tr === 'car' && T.empty) pool.push('fuel', 'fuel', 'fuel');
  const ev = pick(pool); T.paused = true; T.holding = false;
  const resume = () => { closeSheet(); if (T) T.paused = false; };
  const refuel = async kind => { try { const r = await rpc('zhol_refuel', { p: SESSION.id, code: SESSION.code, kind }); if (r.me) ME = r.me; if (T && r.added > 0 && ME.fuel != null) T.fuel = +ME.fuel; return r.added || 0; } catch (e) { return 0; } };
  const bonus = async kind => { try { const r = await rpc('zhol_bonus', { p: SESSION.id, code: SESSION.code, kind }); if (r.me) ME = r.me; if ($('#tripTok')) $('#tripTok').textContent = ME.tokens; return r.tokens || 0; } catch (e) { return 0; } };
  if (ev === 'tea') {
    sheet(`<div style="text-align:center"><div style="font-size:56px">🍵</div><h2>Остановка на чай</h2><p>Апа у дороги налила чай с баурсаками. Силы и топливо +30!</p><button class="big-btn teal" id="ok">Рахмет!</button></div>`, false);
    $('#ok').onclick = async () => { if (T) T.stamina = Math.min(100, T.stamina + 30); if (T && T.tr === 'car') { const n = await refuel('tea'); if (n) toast('⛽ +' + n + '% бензина'); } resume(); };
  } else if (ev === 'gift') {
    const g = pick(Z.GIFT_FINDS);
    sheet(`<div style="text-align:center"><div style="font-size:56px">🎁</div><h2>Подарок для Әже</h2><p>По дороге ты нашёл ${g}. Әже будет рада!</p><button class="big-btn sun" id="ok">Взять</button></div>`, false);
    $('#ok').onclick = async () => { const n = await bonus('gift'); toast(n ? `+${n} 🪙` : 'Лимит подарков на сегодня'); resume(); };
  } else if (ev === 'quiz') {
    const q = pick(Z.QUIZ);
    sheet(`<h2>🧠 Вопрос в дороге</h2><p><b>${esc(q.q)}</b></p>${q.o.map((o, i) => `<button class="opt" data-i="${i}"><span class="i">${'ABC'[i]}</span><b>${esc(o)}</b></button>`).join('')}<div id="qres" class="muted" style="margin-top:10px"></div>`, false);
    $('#sheet').querySelectorAll('[data-i]').forEach(b => b.onclick = async () => {
      $('#sheet').querySelectorAll('[data-i]').forEach(x => x.disabled = true);
      const ok = +b.dataset.i === q.a;
      $('#qres').innerHTML = ok ? 'Дұрыс! Верно! 🎉' : `Почти! Правильный ответ: <b>${esc(q.o[q.a])}</b>`;
      if (ok) { const n = await bonus('quiz'); $('#qres').innerHTML += n ? ` +${n} 🪙` : ' (лимит вопросов на сегодня)'; }
      $('#qres').insertAdjacentHTML('afterend', '<button class="big-btn teal" id="ok">Дальше ▶</button>'); $('#ok').onclick = resume;
    });
  } else if (ev === 'flat') {
    let n = 10;
    sheet(`<div style="text-align:center"><div style="font-size:56px">🛞</div><h2>Прокол колеса!</h2><p>Накачай колесо — нажми насос <b id="pn">${n}</b> раз.</p><button class="big-btn sun" id="pump">🔧 Насос</button></div>`, false);
    $('#pump').onclick = () => { n--; $('#pn').textContent = n; if (n <= 0) { toast('Колесо как новое!'); resume(); } };
  } else if (ev === 'jam') {
    let s = 5;
    sheet(`<div style="text-align:center"><div style="font-size:56px">🚦</div><h2>Пробка</h2><p>Стоим… <b id="js">${s}</b> сек. Самое время позвонить Әже!</p></div>`, false);
    const it = setInterval(() => { s--; const el = $('#js'); if (el) el.textContent = s; if (s <= 0) { clearInterval(it); resume(); } }, 1000);
  } else if (ev === 'oats') {
    sheet(`<div style="text-align:center"><div style="font-size:56px">🌾</div><h2>Поле с овсом</h2><p>Дай коню жем — силы восстановятся полностью.</p><button class="big-btn sun" id="ok">Дать жем</button></div>`, false);
    $('#ok').onclick = () => { if (T) T.stamina = 100; resume(); };
  } else if (ev === 'fuel') {
    sheet(`<div style="text-align:center"><div style="font-size:56px">⛽</div><h2>Заправка по пути</h2><p>Бензин +40%.</p><button class="big-btn teal" id="ok">Заправиться</button></div>`, false);
    $('#ok').onclick = async () => { $('#ok').disabled = true; const n = await refuel('station'); toast(n ? '⛽ Бак +' + n + '%' : 'Заправка уже была совсем недавно'); resume(); };
  }
}

/* ---------- семья ---------- */
function renderFamily() {
  const f = PUB.family, goal = weekGoal(), wk = +f.week_km, all = PUB.nodes.length, kt = f.kordai_today || [];
  let h = `<div class="card"><h3>🏁 Цель недели: все вместе до Кордая</h3><div class="bar"><i style="width:${Math.min(100, 100 * wk / goal)}%"></i></div>
    <div class="muted">${fmt(wk)} из ${fmt(goal)} км — столько выйдет, если каждый из 8 доедет из дома до Ата и Әже. Всего семья проехала: <b>${fmt(f.total_km)} км</b>.</div></div>`;
  h += `<div class="card"><h3>👨‍👩‍👧‍👦 Семейные достижения</h3>
    <div class="row"><div class="av">🏡</div><div class="grow"><b>Все 8 у Ата и Әже в один день</b><small>Сегодня в Кордае: ${kt.length}/8 ${kt.map(id => PUB.players.find(p => p.id === id)?.avatar).join(' ')}</small></div>${kt.length >= 8 ? '<span class="tag ok">Есть!</span>' : ''}</div>
    <div class="row"><div class="av">🗺️</div><div class="grow"><b>Круг по всем городам</b><small>Семья побывала в ${f.all_visited.length} из ${all} мест на карте</small></div>${f.all_visited.length >= all ? '<span class="tag ok">Есть!</span>' : ''}</div></div>`;
  h += raceCard();
  h += `<div class="card"><h3>🏆 Лиги недели (км)</h3><div class="muted">Соревнуются ровесники — так у каждого есть шанс.</div>`;
  for (const lg of ['young', 'mid', 'old']) {
    const ps = PUB.players.filter(p => p.league === lg).sort((a, b) => b.week_km - a.week_km);
    h += `<h4 style="margin:12px 0 2px">${Z.LEAGUES[lg].name} <span class="muted">${Z.LEAGUES[lg].sub}</span></h4>` + ps.map((p, i) => `<div class="row"><div class="av" style="background:${p.color}33">${p.avatar}</div><div class="grow"><b>${i === 0 && p.week_km > 0 ? '👑 ' : ''}${esc(p.name)}</b><small>${p.trip ? `в пути → ${esc(nname(p.trip.path.at(-1)))}` : '📍 ' + esc(nname(p.location))}</small></div><b>${fmt(p.week_km)} км</b></div>`).join('');
  }
  h += `</div>`;
  $('#tab-family').innerHTML = h;
}
/* ---------- награды ---------- */
function renderAch() {
  const N = nodes();
  let h = `<div class="card"><h3>🏅 Мои достижения (${ME.achievements.length}/${Object.keys(Z.ACH).length})</h3><div class="muted">За каждое — +10 🪙</div><div class="grid2" style="margin-top:10px">` +
    Object.entries(Z.ACH).map(([id, a]) => `<div class="ach ${ME.achievements.includes(id) ? 'on' : ''}"><div class="i">${a.i}</div><b>${a.t}</b><small>${a.d}</small></div>`).join('') + `</div></div>`;
  h += `<div class="card"><h3>🎁 Подарки для Әже</h3><div class="muted">Проезжай города — собирай сувениры и вези в Кордай. Новый сувенир: +10 🪙, повтор: +3 🪙.</div>` +
    PUB.nodes.filter(n => n.souvenir && (isOpen(n.id) || ME.gifts.includes(n.id) || ME.delivered.includes(n.id))).map(n => `<div class="row"><div class="av">${ME.delivered.includes(n.id) ? '✅' : ME.gifts.includes(n.id) ? '🎒' : '▫️'}</div><div class="grow"><b>${esc(n.souvenir)}</b><small>${esc(n.name)}${ME.delivered.includes(n.id) ? ' · доставлено Әже' : ME.gifts.includes(n.id) ? ' · в сумке, вези в Кордай' : ''}</small></div></div>`).join('') + (PUB.nodes.some(n => n.souvenir && !isOpen(n.id)) ? `<div class="muted" style="margin-top:8px">🔒 Ещё ${PUB.nodes.filter(n => n.souvenir && !isOpen(n.id)).length} сувениров ждут в закрытых краях.</div>` : '') + `</div>`;
  h += enProfileCard();
  h += `<div class="card"><h3>📊 Моя дорога</h3><div class="stats"><div class="stat"><b>${fmt(ME.km_total)}</b><small>км всего</small></div><div class="stat"><b>${fmt(ME.longest_trip)}</b><small>самая длинная поездка</small></div><div class="stat"><b>${ME.quiz_ok}</b><small>верных ответов</small></div></div>
    <div class="muted" style="margin-top:10px">Транспорт: ${Object.entries(Z.TRANSPORT).map(([id, t]) => `<span style="opacity:${ME.transports.includes(id) ? 1 : .3}">${t.icon}</span>`).join(' ')} · Был(а) в: ${ME.visited.map(v => esc(N[v]?.name)).join(', ')}</div></div>`;
  $('#tab-ach').innerHTML = h;
  $('#enTg').onclick = () => { LS.set('zhol_en_off_' + ME.id, !enOff()); renderAch(); toast(enOff() ? 'Слова в дороге скрыты' : 'Слова в дороге включены 📘'); };
  $('#tab-ach').querySelectorAll('[data-lang]').forEach(b => b.onclick = () => enSetLang(b.dataset.lang));
}
/* ---------- банк ---------- */
const STATUS = { pending: ['wait', 'ждёт родителей'], approved: ['ok', 'подтверждено'], done: ['ok', 'выдано ✓'], rejected: ['no', 'отклонено'] };
const byTxt = r => r.decided_by ? (r.decided_by === 'admin' ? 'Асет' : 'Родители') : '';
const stTag = r => `<span class="tag ${STATUS[r.status][0]}">${r.status === 'done' && r.kind !== 'reward' ? 'подтверждено ✓' : STATUS[r.status][1]}${byTxt(r) && r.status !== 'pending' ? ' · ' + byTxt(r) : ''}</span>`;
function rateText(cfg) { return cfg.rate_preset === 'points' ? 'Жетоны — это очки: на что менять, решают взрослые.' : `1 🪙 = ${cfg.tenge_per_token} ₸ — обмен на настоящие награды делают взрослые.`; }
function renderBank() {
  const cfg = PUB.config, cat = PUB.catalog || [], quests = (PUB.quests || []).filter(q => !q.player || q.player === ME.id);
  let h = `<div class="card"><h3>🏦 Семейный банк</h3><div style="font-size:30px;font-weight:800">${ME.tokens} 🪙</div><div class="muted">${rateText(cfg)} Лимит заработка: ${cfg.daily_token_cap} 🪙 в день. Награды до ${cfg.small_reward_max} 🪙 одобряются сразу, дороже — после «да» родителей (запрос приходит твоим родителям).</div></div>`;
  h += `<div class="card"><h3>🎁 Награды</h3>` + cat.map(it => { const big = it.big || it.cost > cfg.small_reward_max; return `<div class="row"><div class="av">${esc(it.emoji || '🎁')}</div><div class="grow"><b>${esc(it.title)}</b><small>${it.cost} 🪙${cfg.rate_preset !== 'points' ? ' ≈ ' + fmt(it.cost * cfg.tenge_per_token) + ' ₸' : ''}${big ? ' · нужно одобрение' : ''}</small></div><button class="btn p" data-buy="${esc(it.id)}" ${ME.tokens < it.cost ? 'disabled style="opacity:.4"' : ''}>Обменять</button></div>`; }).join('') + `</div>`;
  h += `<div class="card"><h3>📜 Задания от родителей</h3>${quests.length ? quests.map(q => { const r = REQS.find(x => x.kind === 'quest' && x.item?.id === q.id && x.status !== 'rejected'); return `<div class="row"><div class="av">⭐</div><div class="grow"><b>${esc(q.title)}</b><small>+${q.reward} 🪙</small></div>${r ? stTag(r) : `<button class="btn p" data-quest="${q.id}">Сделал!</button>`}</div>`; }).join('') : '<div class="muted">Пока заданий нет.</div>'}</div>`;
  h += `<div class="card"><h3>👟 Мои шаги за день</h3><div class="muted">Посмотри шаги в телефоне (Здоровье / Google Fit) и впиши. 1 шаг ≈ 0,7 м. Км добавятся после подтверждения родителями, раз в день, до 30 000 шагов.</div><div class="inline" style="margin-top:8px"><input id="steps" type="number" inputmode="numeric" min="100" max="30000" placeholder="например, 8000"><button class="btn p" id="stepsBtn">Отправить</button></div></div>`;
  const RB = REQS.filter(r => r.kind !== 'deed');
  h += `<div class="card"><h3>🧾 Мои запросы</h3>${RB.length ? RB.map(r => `<div class="row"><div class="grow"><b>${r.kind === 'reward' ? esc(r.item.title) + ' · ' + r.cost + ' 🪙' : r.kind === 'quest' ? '⭐ ' + esc(r.item.title) : '👟 ' + r.item.steps + ' шагов = ' + r.item.km + ' км'}</b><small>${new Date(r.created_at).toLocaleDateString('ru-RU')}${r.note ? ' · ' + esc(r.note) : ''}</small></div>${stTag(r)}</div>`).join('') : '<div class="muted">Пока пусто.</div>'}</div>`;
  $('#tab-bank').innerHTML = h;
  $('#tab-bank').querySelectorAll('[data-buy]').forEach(b => b.onclick = () => { const it = cat.find(x => x.id === b.dataset.buy); if (confirm(`Обменять ${it.cost} 🪙 на «${it.title}»?`)) req('reward', { id: it.id }); });
  $('#tab-bank').querySelectorAll('[data-quest]').forEach(b => b.onclick = () => req('quest', { id: +b.dataset.quest }));
  $('#stepsBtn').onclick = () => req('steps', { steps: +$('#steps').value });
}
async function req(kind, payload) {
  try { const r = await rpc('zhol_request', { p: SESSION.id, code: SESSION.code, kind, payload }); if (!r.ok) return toast(errText(r.error)); ME = r.me; REQS = r.requests; toast('Отправлено! Рахмет 🙌'); renderApp(); }
  catch (e) { toast(e.offline ? 'Нет сети' : e.message); }
}

/* ---------- вход для родителей (только просмотр) ---------- */
$('#toFamily').onclick = async () => {
  let fams = [];
  try { fams = await rpc('zhol_families'); } catch (e) { return toast('Нет сети'); }
  sheet(`<h2>👪 Вход для родителей</h2><div class="muted">Выберите свою семью. Здесь видно прогресс ваших детей и их запросы (награды, шаги, задания) — их можно подтвердить или отклонить.</div>` +
    fams.map(f => `<button class="opt" data-fam="${f.id}"><span class="i">${f.all ? '👨‍👩‍👧‍👦' : '🏡'}</span><span><b>${esc(f.name)}</b><small>${f.all ? 'все 8: ' + f.kids.map(k => k.avatar).join(' ') : f.kids.map(k => k.avatar + ' ' + esc(k.name)).join(', ')}</small></span></button>`).join('') +
    `<button class="btn" style="width:100%;margin-top:12px" onclick="document.getElementById('modal').click()">Отмена</button>`);
  $('#sheet').querySelectorAll('[data-fam]').forEach(b => b.onclick = () => {
    const f = fams.find(x => x.id === b.dataset.fam);
    codePad(`🏡 ${esc(f.name)}`, 'Введите код семьи (4–6 цифр) и нажмите OK', { min: 4, max: 6, onSubmit: async (code, fail) => {
      try { const r = await rpc('zhol_family_login', { f: f.id, code }); if (!r.ok) return fail(errText(r.error === 'bad_code' ? 'bad_fcode' : r.error));
        FAM = { id: f.id, code }; LS.set('zhol_fam', FAM); LS.set('zhol_mode', 'family'); closeSheet(); enterFamily(r); }
      catch (e) { fail(e.offline ? 'Нет сети' : e.message); }
    } });
  });
};
ERR.bad_fcode = 'Неверный код семьи';
// 🧪 тестовый вход (для Асета): скрытый ребёнок и скрытая семья «Тест» — не видны детям, не входят в итоги, рейтинги и общий чат
$('#toTest').onclick = () => {
  sheet(`<h2>🧪 Тестовый вход</h2><div class="muted">Для проверки функций. Тестовый игрок не виден детям и родителям, не попадает в рейтинги, итоги семьи и общий чат; жарыс с настоящими детьми невозможен.</div>
    <button class="opt" id="tKid"><span class="i">🧪</span><span><b>Тест (Асет) — как ребёнок</b><small>код из 4 цифр</small></span></button>
    <button class="opt" id="tFam"><span class="i">👪</span><span><b>Семья «Тест» — как родитель</b><small>код из 6 цифр · подтверждать дела и запросы тестового, сброс прогресса</small></span></button>
    <div class="muted" style="margin-top:12px">👋 Гостевой вход (действует до 23:59 18.11 по Алматы)</div>
    <button class="opt" id="gKid"><span class="i">🐣</span><span><b>Айзере — как ребёнок</b><small>гостевой код</small></span></button>
    <button class="opt" id="gFam"><span class="i">👀</span><span><b>Семья «Гость» — как родитель</b><small>гостевой код · просмотр всех детей</small></span></button>
    <button class="btn" style="width:100%;margin-top:12px" onclick="document.getElementById('modal').click()">Отмена</button>`);
  const kidLogin = (id, title, sub, len) => codePad(title, sub, { min: len, max: len, onSubmit: async (code, fail) => {
    try { const r = await rpc('zhol_login', { p: id, code }); if (!r.ok) return fail(errText(r.error));
      LS.set('zhol_test', true); SESSION = { id, code }; LS.set('zhol_mode', 'kid'); LS.set('zhol_me', SESSION); ME = r.me; REQS = r.requests; try { await loadPub(); } catch (e) {} closeSheet(); enterApp(); }
    catch (e) { fail(e.offline ? 'Нет сети' : e.message); }
  } });
  const famLogin = (id, title, sub, len) => codePad(title, sub, { min: len, max: len, onSubmit: async (code, fail) => {
    try { const r = await rpc('zhol_family_login', { f: id, code }); if (!r.ok) return fail(errText(r.error === 'bad_code' ? 'bad_fcode' : r.error));
      FAM = { id, code }; LS.set('zhol_fam', FAM); LS.set('zhol_mode', 'family'); closeSheet(); enterFamily(r); }
    catch (e) { fail(e.offline ? 'Нет сети' : e.message); }
  } });
  $('#tKid').onclick = () => kidLogin(Z.TEST_KID, '🧪 Тест (Асет)', 'Код тестового ребёнка', 4);
  $('#tFam').onclick = () => famLogin(Z.TEST_FAM, '👪 Семья «Тест»', 'Код тестовой семьи (6 цифр)', 6);
  $('#gKid').onclick = () => kidLogin('ztest_g1', '🐣 Сәлем, Айзере!', 'Гостевой код (4 цифры)', 4);
  $('#gFam').onclick = () => famLogin('ztest_g', '👀 Семья «Гость»', 'Гостевой код (4 цифры)', 4);
};
ERR.expired = 'Срок гостевого входа закончился';
ERR.read_only = 'В гостевом режиме это недоступно — только просмотр';
async function testReset() {
  if (!FAM || !isTest(FAM.id) || !confirm('Сбросить весь прогресс тестового ребёнка? (км, жетоны, звёзды, края, запросы, его сообщения — домой в Астану)')) return;
  try { const r = await rpc('zhol_test_reset', { f: FAM.id, code: FAM.code }); if (!r.ok) return toast(errText(r.error)); renderFamilyView(r); toast('Тестовый сброшен 🧪'); }
  catch (e) { toast(e.offline ? 'Нет сети' : e.message); }
}
let famPoll;
function enterFamily(r) {
  ME = null; show('parent'); renderFamilyView(r); setTimeout(() => chatTick(), 300);
  clearInterval(famPoll); famPoll = setInterval(refreshFamily, 60000);
}
async function refreshFamily() {
  if ($('#parent').classList.contains('hidden') || !FAM) return;
  try { const r = await rpc('zhol_family_login', { f: FAM.id, code: FAM.code }); if (r.ok) renderFamilyView(r); else if (r.error === 'bad_code' || r.error === 'expired') { famLogout(); alert(r.error === 'expired' ? 'Срок гостевого входа закончился' : 'Код семьи изменился — войдите заново'); } } catch (e) {}
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) { if (vis('parent')) refreshFamily(); chatTick(true); } });
function famLogout() { chatClose(); chatBadge(0); clearInterval(famPoll); LS.del('zhol_fam'); LS.del('zhol_famdata'); LS.set('zhol_mode', ''); FAM = null; FAMDATA = null; show('login'); loadPub().then(renderKids).catch(() => {}); }
$('#famExit').onclick = () => { if (confirm('Выйти из семейного просмотра?')) famLogout(); };
$('#famRefresh').onclick = () => { refreshFamily(); toast('Обновлено'); };
const fdt = s => new Date(s).toLocaleString('ru-RU', { timeZone: 'Asia/Almaty', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
function tripLine(p) {
  if (!p.trip) return `📍 ${p.location === 'KOR' ? 'в Кордае, у Ата и Әже 🏡' : 'в ' + esc(nname(p.location))}`;
  const T = Z.TRANSPORT[p.trip.transport], pct = Math.round(100 * p.trip.done / p.trip.total), org = p.trip.origin || p.trip.path[0];
  return `${T.icon} ${esc(nname(org))} → <b>${esc(nname(p.trip.path.at(-1)))}</b>${org !== p.trip.path[0] ? `, сейчас ${T.icon} из ${esc(genName(p.trip.path[0]))}` : ''} · ${T.name.toLowerCase()} · ${pct}%`;
}
function actLine(a, P) {
  const p = P(a.player), d = a.data || {}, who = `${p.avatar} ${esc(p.name)}`;
  if (a.kind === 'arrive') return `${who} доехал(а): ${esc(nname(d.from))} → <b>${esc(nname(d.to))}</b> ${Z.TRANSPORT[d.transport]?.icon || ''} · ${fmt(d.km)} км`;
  if (a.kind === 'start') { const path = d.path || []; return `${who} выехал(а): ${esc(nname(path[0]))} → ${esc(nname(path.at(-1)))} ${Z.TRANSPORT[d.transport]?.icon || ''} · ${fmt(d.total)} км`; }
  if (a.kind === 'switch') return `${who} пересел(а) в ${esc(locName(d.at))}: ${Z.TRANSPORT[d.old]?.icon || ''} → ${Z.TRANSPORT[d.new]?.icon || ''} (едет в ${esc(nname(d.to))})`;
  if (a.kind === 'ach') { const A = Z.ACH[d.a]; return `${who} получил(а) достижение ${A ? A.i + ' «' + A.t + '»' : ''}`; }
  return who;
}
function renderFamilyView(r) {
  FAMDATA = r; LS.set('zhol_famdata', r); PUB = r.pub; LS.set('zhol_pub', r.pub);
  const N = nodes(), P = id => PUB.players.find(p => p.id === id) || { avatar: '?', name: id };
  $('#famName').textContent = r.family.name;
  const kidCard = k => {
    const trips = r.activity.filter(a => a.player === k.id && a.kind === 'arrive').slice(0, 3);
    const pct = k.trip ? Math.min(100, 100 * k.trip.done / k.trip.total) : null;
    return `<div class="card kidcard"><div class="row" style="border:0;padding-top:0"><div class="av" style="background:${k.color};width:48px;height:48px;font-size:28px">${k.avatar}</div><div class="grow"><b style="font-size:18px">${esc(k.name)}</b><small>${k.age} лет · ${esc(k.school)} · ${Z.LEAGUES[k.league].name}</small></div><div class="chip" style="background:#fff1cf;color:#3a2400"><b>${k.tokens}</b> 🪙</div></div>
      <div class="kstatus">${tripLine(k)}</div>${pct !== null ? `<div class="bar"><i style="width:${pct}%"></i></div><div class="muted">${fmt(k.trip.done)} из ${fmt(k.trip.total)} км</div>` : ''}
      <div class="stats"><div class="stat"><b>${fmt(k.today_km)}</b><small>км сегодня</small></div><div class="stat"><b>${fmt(k.week_km)}</b><small>км за неделю</small></div><div class="stat"><b>${fmt(k.km_total)}</b><small>км всего</small></div></div>
      <div class="kblock"><b>⭐ Добрые дела:</b> ${k.stars || 0} ⭐ · открыто краёв ${(k.unlocked || []).length} из ${REGS().length}${(k.unlocked || []).length ? ' — ' + k.unlocked.map(u => esc(regInfo(u).n)).join(', ') : ''}${nextReg(k) ? ` · до «${esc(nextReg(k).n)}» ещё ${Math.max(0, nextReg(k).need - (k.stars || 0))} ⭐` : ''}</div>${enFamLine(k)}
      <div class="kblock"><b>🗺️ Города (${k.visited.length}):</b> ${k.visited.map(v => esc(N[v]?.name || v)).join(', ')}</div>
      <div class="kblock"><b>🎁 Сувениры:</b> ${k.delivered.length ? 'доставлено Әже — ' + k.delivered.map(g => esc(N[g]?.souvenir)).join(', ') : 'пока не доставлено'}${k.gifts.length ? '; в сумке — ' + k.gifts.map(g => esc(N[g]?.souvenir)).join(', ') : ''}</div>
      <div class="kblock"><b>🏅 Достижения (${k.achievements.length}/${Object.keys(Z.ACH).length}):</b> ${k.achievements.length ? k.achievements.map(a => `<span class="tag" title="${esc(Z.ACH[a]?.d)}">${Z.ACH[a]?.i} ${esc(Z.ACH[a]?.t || a)}</span>`).join(' ') : 'пока нет'}</div>
      <div class="kblock"><b>🛣️ Последние поездки:</b> ${trips.length ? trips.map(a => `<div class="muted">${fdt(a.at)} — ${esc(nname(a.data.from))} → ${esc(nname(a.data.to))} ${Z.TRANSPORT[a.data.transport]?.icon || ''} ${fmt(a.data.km)} км</div>`).join('') : '<span class="muted">пока нет завершённых</span>'}</div></div>`;
  };
  const RQ = r.requests || [], open = RQ.filter(q => q.status === 'pending' || q.status === 'approved'), past = RQ.filter(q => q.status === 'done' || q.status === 'rejected').slice(0, 5);
  const KP = id => r.kids.find(k => k.id === id) || P(id);
  const RO = !!r.family.ro, mine = id => KP(id).family === r.family.id;
  const rqRow = q => { const k = KP(q.player); if (RO && !mine(q.player)) return `<div class="row rq"><div class="av" style="background:${k.color || '#eee'}33">${k.avatar}</div><div class="grow"><b>${esc(k.name)}: ${kindTxt(q)}</b><small>${fdt(q.created_at)} · ${stTag(q)} · 👀 решают родители</small></div></div>`; return `<div class="row rq"><div class="av" style="background:${k.color || '#eee'}33">${k.avatar}</div><div class="grow"><b>${esc(k.name)}: ${kindTxt(q)}</b><small>${fdt(q.created_at)} · ${stTag(q)}${q.note ? ' · ' + esc(q.note) : ''}</small></div>${q.status === 'pending' ? `<div class="rqbtns"><button class="btn p" data-fdec="${q.id}" data-s="approved">✅ Подтвердить</button><button class="btn r" data-fdec="${q.id}" data-s="rejected">❌ Отклонить</button></div>` : q.status === 'approved' ? `<div class="rqbtns"><button class="btn" data-fdec="${q.id}" data-s="done">🎁 Выдано</button></div>` : ''}</div>`; };
  let h = `<div class="card fam-reqs" id="famReqs"><h3>📬 Запросы детей ${r.pending ? `<span class="nb">${r.pending}</span>` : ''}</h3><div class="muted">Подтвердите или отклоните — ребёнок сразу увидит ответ. Подтверждённую награду отметьте «Выдано», когда отдадите её. ⭐ Добрые дела (оценки, чтение, помощь дома) подтверждайте, только если это правда — за звёзды открываются новые города.</div>${open.length ? open.map(rqRow).join('') : '<div class="empty">Новых запросов нет 👍</div>'}${past.length ? `<details><summary>Недавно решённые</summary>${past.map(rqRow).join('')}</details>` : ''}</div>`;
  $('#famBadge').innerHTML = r.pending ? `📬 <b>${r.pending}</b>` : ''; $('#famBadge').classList.toggle('hidden', !r.pending);
  let kh = '';
  if (r.family.all) for (const fm of r.families || []) { const ks = r.kids.filter(k => k.family === fm.id); if (ks.length) kh += `<h2 class="famhead">🏡 ${esc(fm.name)}</h2>` + ks.map(kidCard).join(''); }
  else kh = r.kids.map(kidCard).join('');
  if (r.family.all && r.kids.some(k => k.family === r.family.id)) kh = `<h2 class="famhead">🐣 Ваш гостевой ребёнок</h2>` + r.kids.filter(k => k.family === r.family.id).map(kidCard).join('') + kh;
  h += `<div class="fam-kids">${kh}</div>`;
  const f = PUB.family, goal = weekGoal(), wk = +f.week_km;
  h += `<div class="fam-all"><div class="card"><h3>🏁 Вся семья</h3><div class="muted">Цель недели — все 8 детей доезжают из дома до Ата и Әже (${fmt(goal)} км).</div><div class="bar"><i style="width:${Math.min(100, 100 * wk / goal)}%"></i></div>
      <div class="stats"><div class="stat"><b>${fmt(wk)}</b><small>км за неделю</small></div><div class="stat"><b>${Math.round(100 * wk / goal)}%</b><small>цели недели</small></div><div class="stat"><b>${fmt(f.total_km)}</b><small>км всего</small></div></div></div>
    <div class="card"><h3>🗺️ Кто где и куда едет</h3><div class="mapwrap"><svg id="pmap" viewBox="0 0 1000 575"></svg></div>
      ${PUB.players.map(p => `<div class="row"><div class="av" style="background:${p.color}33">${p.avatar}</div><div class="grow"><b>${esc(p.name)}</b><small>${tripLine(p)}</small></div></div>`).join('')}</div>
    ${raceCard(r.family.all ? null : c => r.kids.some(k => k.id === c.challenger || k.id === c.opponent))}
    <div class="card"><h3>🏆 Рейтинг недели</h3>${[...PUB.players].sort((a, b) => b.week_km - a.week_km || b.km_total - a.km_total).map((p, i) => `<div class="row"><div style="width:22px;font-weight:800">${i + 1}</div><div class="av" style="background:${p.color}33">${p.avatar}</div><div class="grow"><b>${esc(p.name)}</b><small>${Z.LEAGUES[p.league].name} · всего ${fmt(p.km_total)} км</small></div><b>${fmt(p.week_km)} км</b></div>`).join('')}</div>
    <div class="card"><h3>🕑 Последние события (${r.family.all ? 'все дети' : 'ваши дети'})</h3>${r.activity.length ? r.activity.slice(0, 15).map(a => `<div class="row"><div class="grow">${actLine(a, P)}<small>${fdt(a.at)}</small></div></div>`).join('') : '<div class="muted">Пока событий нет — дети ещё не выезжали.</div>'}</div></div>`;
  if (RO) h = `<div class="card testcard"><h3>👀 Гостевой просмотр</h3><div class="muted">Вы видите всех детей: карту, поездки, км, достижения и семейный чат — только просмотр, без подтверждений, удаления и сообщений. Подтверждать можно дела гостевого ребёнка «Айзере» (она скрыта от настоящих детей и рейтингов). Вход действует до 23:59 18.11 по Алматы.</div></div>` + h;
  else if (isTest(r.family.id)) h = `<div class="card testcard"><h3>🧪 Тестовый режим</h3><div class="muted">Эта семья и ребёнок «Тест (Асет)» скрыты от всех: их нет у детей, в рейтингах, итогах и общем чате.</div><button class="big-btn" id="tReset">♻️ Сбросить тестового ребёнка</button></div>` + h;
  $('#parentMain').innerHTML = h;
  if ($('#tReset')) $('#tReset').onclick = testReset;
  mapZoomInit(); renderMap($('#pmap'), null);
  $('#parentMain').querySelectorAll('[data-fdec]').forEach(b => b.onclick = () => famDecide(+b.dataset.fdec, b.dataset.s, b));
}
function kindTxt(r) { if (r.kind === 'deed') return deedTxt(r); return r.kind === 'reward' ? `${esc(r.item.emoji || '🎁')} ${esc(r.item.title)} · ${r.cost} 🪙` : r.kind === 'quest' ? `⭐ ${esc(r.item.title)} (+${r.item.reward} 🪙)` : `👟 ${r.item.steps} шагов → ${r.item.km} км`; }
ERR.not_your_kid = 'Это запрос не вашего ребёнка'; ERR.no_request = 'Запрос не найден'; ERR.approve_first = 'Сначала подтвердите'; ERR.already = 'Уже решено';
async function famDecide(id, status, btn) {
  if (!FAM) return;
  let note = '';
  if (status === 'rejected') { const v = prompt('Отклонить запрос? Можно написать ребёнку пару слов (необязательно):', ''); if (v === null) return; note = v.slice(0, 120); }
  if (btn) btn.disabled = true;
  try { const r = await rpc('zhol_family_decide', { f: FAM.id, code: FAM.code, id, status, note }); if (!r.ok) { toast(errText(r.error), 2500); refreshFamily(); return; } renderFamilyView(r); toast(status === 'approved' ? 'Подтверждено ✅' : status === 'rejected' ? 'Отклонено' : 'Отмечено: выдано 🎁'); }
  catch (e) { toast(e.offline ? 'Нет сети' : e.message); if (btn) btn.disabled = false; }
}

/* ---------- родители ---------- */
async function adm(action, payload = {}) {
  try { const r = await rpc('zhol_admin', { pin: PIN, action, payload }); if (!r.ok) { alert(errText(r.error)); if (r.error === 'bad_pin' || r.error === 'locked') { show('login'); } return false; } ADMIN = r; renderAdmin(); return true; }
  catch (e) { alert(e.offline ? 'Нет сети' : e.message); return false; }
}
$('#adminExit').onclick = () => { chatClose(); chatBadge(0); PIN = null; ADMIN = null; show('login'); loadPub().then(renderKids).catch(() => {}); };
function renderAdmin() {
  const A = ADMIN, cfg = A.config, P = id => A.players.find(p => p.id === id) || { avatar: '?', name: id };
  let h = `<div class="card"><h3>📬 Запросы детей</h3>${A.requests.filter(r => r.status === 'pending' || r.status === 'approved').map(r => `<div class="row"><div class="av">${P(r.player).avatar}</div><div class="grow"><b>${esc(P(r.player).name)}: ${kindTxt(r)}</b><small>${new Date(r.created_at).toLocaleString('ru-RU')} · ${stTag(r)}</small></div>
     ${r.status === 'pending' ? `<button class="btn p" data-dec="${r.id}" data-s="approved">✓</button><button class="btn r" data-dec="${r.id}" data-s="rejected">✕</button>` : `<button class="btn" data-dec="${r.id}" data-s="done">Выдано</button>`}</div>`).join('') || '<div class="muted">Новых запросов нет.</div>'}</div>`;
  h += `<div class="card"><h3>👧👦 Дети</h3><table><tr><th></th><th>Где</th><th>км нед./всего</th><th>🪙</th><th>🎫</th></tr>${A.players.map(p => `<tr><td>${p.avatar} <b>${esc(p.name)}</b>${p.locked ? ' 🔒' : ''}<br><button class="btn" style="padding:4px 8px;margin-top:4px" data-act="${p.id}">⚙︎</button></td><td>${p.trip ? '→ ' + esc(nname(p.trip.path.at(-1))) + ' (' + fmt(p.trip.done) + '/' + fmt(p.trip.total) + ')' : esc(nname(p.location))}</td><td>${fmt(p.week_km)} / ${fmt(p.km_total)}</td><td>${p.tokens}<br><small class="muted">сегодня ${p.today_tokens}</small></td><td>${p.tickets}</td></tr>`).join('')}</table></div>`;
  h += `<div class="card"><h3>💱 Курс жетонов и лимиты</h3>
    <label>Курс</label><select id="cPreset"><option value="5">1 🪙 = 5 ₸</option><option value="10">1 🪙 = 10 ₸</option><option value="points">Только очки (без денег)</option><option value="custom">Свой курс</option></select>
    <label>₸ за 1 жетон (для «свой курс»)</label><input id="cTenge" type="number" min="0" value="${cfg.tenge_per_token}">
    <label>Лимит жетонов в день на ребёнка</label><input id="cCap" type="number" min="1" value="${cfg.daily_token_cap}">
    <label>Сколько км за 1 жетон</label><input id="cKm" type="number" min="1" value="${cfg.km_per_token}">
    <label>Награды до N жетонов — без одобрения</label><input id="cSmall" type="number" min="0" value="${cfg.small_reward_max}">
    <label>Билет на самолёт за каждые N км по земле</label><input id="cTicket" type="number" min="50" value="${cfg.ticket_every_km}">
    <label>Лимит км в день на ребёнка</label><input id="cKmCap" type="number" min="50" value="${cfg.daily_km_cap}">
    <button class="big-btn teal" id="cSave">Сохранить</button></div>`;
  h += deedAdminCard(cfg);
  h += `<div class="card"><h3>🎁 Каталог наград</h3><div class="muted">Пример — меняйте как удобно. «Крупная» = всегда нужно ваше одобрение.</div><div id="catRows">${A.catalog.map(catRow).join('')}</div>
    <button class="btn" id="catAdd" style="margin-top:8px">+ Добавить</button> <button class="btn p" id="catSave">Сохранить каталог</button></div>`;
  h += `<div class="card"><h3>📜 Бонусные задания</h3><label>Задание</label><input id="qT" placeholder="например: прочитать 20 страниц и рассказать Әже по телефону"><div class="inline" style="margin-top:8px"><input id="qR" type="number" value="15" min="1" style="max-width:90px"> 🪙 <select id="qP" style="flex:1"><option value="">Всем</option>${A.players.map(p => `<option value="${p.id}">${esc(p.name)}</option>`).join('')}</select><button class="btn p" id="qAdd">Дать</button></div>
    ${A.quests.map(q => `<div class="row"><div class="grow"><b>${esc(q.title)}</b><small>+${q.reward} 🪙 · ${q.player ? esc(P(q.player).name) : 'всем'}</small></div><button class="btn" data-endq="${q.id}">Завершить</button></div>`).join('')}</div>`;
  h += `<div class="card"><h3>👪 Коды семей (просмотр)</h3><div class="muted">Родители входят через «Вход для родителей»: видят прогресс своих детей и подтверждают/отклоняют их запросы. Курс, каталог, лимиты и коды меняет только администратор.</div>${(A.families || []).map(f => `<label>${esc(f.name)}${f.locked ? ' 🔒' : ''}</label><div class="inline"><input type="password" inputmode="numeric" maxlength="6" placeholder="новый код, 4–6 цифр" data-fcode="${f.id}"><button class="btn p" data-fsave="${f.id}">Сменить</button></div>`).join('')}</div>`;
  h += `<div class="card"><h3>🔐 PIN администратора</h3><div class="inline"><input id="newPin" type="password" inputmode="numeric" placeholder="новый PIN, 4–8 цифр"><button class="btn p" id="pinSave">Сменить</button></div></div>`;
  h += `<div class="card"><h3>🛡️ Защита от накрутки</h3><div class="muted">Сервер не засчитывает больше 12 тапов в секунду, ограничивает скорость каждого транспорта и дневные лимиты. Последние срабатывания:</div>${A.suspicious.length ? A.suspicious.map(s => `<div class="row"><div class="grow"><b>${esc(P(s.player).name)}: ${s.kind === 'too_fast' ? 'слишком частые тапы' : 'урезано по скорости'}</b><small>${new Date(s.at).toLocaleString('ru-RU')}</small></div></div>`).join('') : '<div class="muted">Пусто 👍</div>'}</div>`;
  $('#adminMain').innerHTML = h;
  $('#cPreset').value = cfg.rate_preset || '10';
  $('#adminMain').querySelectorAll('[data-fsave]').forEach(b => b.onclick = async () => { const id = b.dataset.fsave, v = $('#adminMain').querySelector('[data-fcode="' + id + '"]').value; if (!/^\d{4,6}$/.test(v)) return alert('Код — от 4 до 6 цифр'); if (await adm('set_family_code', { family: id, code: v })) alert('Код семьи изменён'); });
  $('#adminMain').querySelectorAll('[data-dec]').forEach(b => b.onclick = () => adm('decide', { id: +b.dataset.dec, status: b.dataset.s, note: b.dataset.s === 'rejected' ? (prompt('Комментарий ребёнку (необязательно)') || '') : '' }));
  $('#adminMain').querySelectorAll('[data-endq]').forEach(b => b.onclick = () => adm('end_quest', { id: +b.dataset.endq }));
  $('#adminMain').querySelectorAll('[data-act]').forEach(b => b.onclick = () => kidActions(P(b.dataset.act)));
  $('#cSave').onclick = () => {
    const pr = $('#cPreset').value, tenge = pr === '5' ? 5 : pr === '10' ? 10 : pr === 'points' ? 0 : +$('#cTenge').value;
    adm('set_config', { config: { rate_preset: pr, tenge_per_token: tenge, daily_token_cap: +$('#cCap').value, km_per_token: +$('#cKm').value, small_reward_max: +$('#cSmall').value, ticket_every_km: +$('#cTicket').value, daily_km_cap: +$('#cKmCap').value } });
  };
  bindDeedAdmin(cfg);
  $('#catAdd').onclick = () => $('#catRows').insertAdjacentHTML('beforeend', catRow({ id: 'r' + Date.now(), title: '', cost: 50, emoji: '🎁' }));
  $('#catSave').onclick = () => {
    const rows = [...$('#catRows').querySelectorAll('.catrow')].map(r => ({ id: r.dataset.id, emoji: r.querySelector('.ce').value || '🎁', title: r.querySelector('.ct').value.trim(), cost: Math.max(1, +r.querySelector('.cc').value || 1), big: r.querySelector('.cb').checked })).filter(x => x.title);
    adm('set_catalog', { catalog: rows });
  };
  $('#qAdd').onclick = () => { if (!$('#qT').value.trim()) return; adm('add_quest', { title: $('#qT').value.trim(), reward: +$('#qR').value, player: $('#qP').value }); };
  $('#pinSave').onclick = async () => { const v = $('#newPin').value; if (!/^\d{4,8}$/.test(v)) return alert('PIN — от 4 до 8 цифр'); if (await adm('set_pin', { new_pin: v })) { PIN = v; alert('PIN изменён'); } };
}
function catRow(it) { return `<div class="catrow inline" data-id="${esc(it.id)}" style="margin-top:6px"><input class="ce" value="${esc(it.emoji)}" style="max-width:52px"><input class="ct" value="${esc(it.title)}" placeholder="Награда"><input class="cc" type="number" value="${it.cost}" style="max-width:80px"><label style="margin:0;font-weight:500"><input class="cb" type="checkbox" style="width:auto" ${it.big ? 'checked' : ''}> крупная</label><button class="btn r" onclick="this.parentNode.remove()">✕</button></div>`; }
function kidActions(p) {
  sheet(`<h2>${p.avatar} ${esc(p.name)}</h2><div class="muted">${p.age} лет · ${Z.LEAGUES[p.league].name}</div>
    <label>Новый код входа (4 цифры)</label><div class="inline"><input id="kc" inputmode="numeric" maxlength="4" placeholder="1234"><button class="btn p" id="kcS">Сохранить</button></div>
    <label>Жетоны (+/−)</label><div class="inline"><input id="kt" type="number" placeholder="например 20 или -10"><button class="btn p" id="ktS">Применить</button></div>
    <label>Билеты на самолёт (+/−)</label><div class="inline"><input id="kb" type="number" placeholder="1"><button class="btn p" id="kbS">Применить</button></div>
    <label>⭐ Звёзды добрых дел (+/−), сейчас ${p.stars || 0}</label><div class="inline"><input id="ks" type="number" placeholder="например 5 или -3"><button class="btn p" id="ksS">Применить</button></div>
    <label>🔓 Открыть край вручную</label><div class="inline"><select id="kr" style="flex:1">${REGS().filter(R => !(p.unlocked || []).includes(R.id)).map(R => `<option value="${R.id}">${R.e || ''} ${esc(R.n)} (${R.need} ⭐)</option>`).join('') || '<option value="">все края открыты</option>'}</select><button class="btn p" id="krS">Открыть</button></div>
    <button class="btn" id="kHome" style="margin-top:14px;width:100%">Вернуть домой (${esc(nname(p.home))}) и отменить поездку</button>
    <button class="btn" style="margin-top:8px;width:100%" onclick="document.getElementById('modal').click()">Закрыть</button>`);
  $('#kcS').onclick = async () => { const v = $('#kc').value; if (!/^\d{4}$/.test(v)) return alert('Ровно 4 цифры'); if (await adm('set_code', { player: p.id, code: v })) { closeSheet(); alert(`Новый код для ${p.name}: ${v}`); } };
  $('#ktS').onclick = async () => { if (await adm('adjust', { player: p.id, tokens: +$('#kt').value || 0 })) closeSheet(); };
  $('#kbS').onclick = async () => { if (await adm('adjust', { player: p.id, tickets: +$('#kb').value || 0 })) closeSheet(); };
  $('#ksS').onclick = async () => { if (await adm('stars', { player: p.id, n: +$('#ks').value || 0 })) closeSheet(); };
  $('#krS').onclick = async () => { const v = $('#kr').value; if (v && confirm('Открыть край для ' + p.name + '?') && await adm('unlock', { player: p.id, region: v })) closeSheet(); };
  $('#kHome').onclick = async () => { if (confirm('Точно?') && await adm('move_home', { player: p.id })) closeSheet(); };
}

window.addEventListener('online', () => { setNet(true); if (ME && SESSION) refresh(); });
window.addEventListener('offline', () => setNet(false));
/* ---------- жарыс (челлендж) ---------- */
const RACE_TR = ['walk', 'bike', 'horse', 'car'];
const pl = id => PUB.players.find(p => p.id === id) || { avatar: '❔', name: id };
const openCh = id => (PUB.challenges || []).find(c => (c.challenger === id || c.opponent === id) && (c.status === 'pending' || c.status === 'active'));
function racePct(c, id) {
  const p = pl(id);
  if (p.trip && +p.trip.challenge === c.id) return Math.min(100, 100 * p.trip.done / p.trip.total);
  const arr = id === c.challenger ? c.challenger_arrived_at : c.opponent_arrived_at;
  return arr ? 100 : null;
}
function chLine(c) {
  const A = pl(c.challenger), B = pl(c.opponent), T = Z.TRANSPORT[c.transport];
  let st;
  if (c.status === 'pending') st = 'ждёт ответа';
  else if (c.status === 'active') st = `${A.avatar} ${Math.round(racePct(c, c.challenger) ?? 0)}% · ${B.avatar} ${Math.round(racePct(c, c.opponent) ?? 0)}%`;
  else if (c.status === 'finished') st = `🏆 победил(а) ${esc(pl(c.winner).name)}`;
  else if (c.status === 'cancelled' && c.winner) st = `${esc(pl(c.cancelled_by).name)} сошёл(ла) с дистанции — победа ${esc(pl(c.winner).name)}`;
  else st = 'отменён';
  return `<div class="row"><div class="av">⚔️</div><div class="grow"><b>${A.avatar} ${esc(A.name)} vs ${B.avatar} ${esc(B.name)}</b><small>${esc(nname(c.path[0]))} → ${esc(nname(c.path.at(-1)))} · ${T.icon} ${T.name.toLowerCase()} · ${fmt(c.total)} км</small><small>${st}</small></div></div>`;
}
function raceCard(list) {
  const cs = (PUB.challenges || []).filter(list || (() => true));
  return `<div class="card"><h3>⚔️ Жарыс — вызовы и гонки</h3>${cs.length ? cs.map(chLine).join('') : '<div class="muted">Пока гонок нет. Жарыс можно начать, когда двое детей в одном месте.</div>'}</div>`;
}
function racePanel() {
  const c = openCh(ME.id);
  if (c && c.status === 'pending' && c.opponent === ME.id) {
    const A = pl(c.challenger), T = Z.TRANSPORT[c.transport];
    return `<div class="race-box"><b>⚔️ ${A.avatar} ${esc(A.name)} вызывает тебя на жарыс!</b><div class="muted">${esc(nname(c.path[0]))} → ${esc(nname(c.path.at(-1)))} · ${T.icon} ${T.name} · ${fmt(c.total)} км. Кто первый доедет — +15 🪙.</div>
      <div class="inline" style="margin-top:8px"><button class="btn p" id="raceYes">Принять ⚔️</button><button class="btn r" id="raceNo">Отказаться</button></div></div>`;
  }
  if (c && c.status === 'pending') return `<div class="race-box"><b>⚔️ Ждём ответа от ${pl(c.opponent).avatar} ${esc(pl(c.opponent).name)}</b><div class="muted">${esc(nname(c.path[0]))} → ${esc(nname(c.path.at(-1)))} · ${Z.TRANSPORT[c.transport].icon}. Вызов действует 24 часа.</div><button class="btn" id="raceCancel" style="margin-top:8px">Отменить вызов</button></div>`;
  if (c && c.status === 'active') { const o = c.challenger === ME.id ? c.opponent : c.challenger; return `<div class="race-box"><b>⚔️ Идёт жарыс с ${pl(o).avatar} ${esc(pl(o).name)}</b><div class="muted">Ты ${Math.round(racePct(c, ME.id) ?? 0)}% · ${esc(pl(o).name)} ${Math.round(racePct(c, o) ?? 0)}%</div></div>`; }
  if (!ME.trip) return `<button class="big-btn sun" id="raceNew">⚔️ Жарыс — вызвать на гонку</button>`;
  return '';
}
function bindRace() {
  const c = openCh(ME.id);
  if ($('#raceYes')) $('#raceYes').onclick = async () => { try { const r = await rpc('zhol_challenge_respond', { p: SESSION.id, code: SESSION.code, id: c.id, accept: true }); if (!r.ok) { toast(errText(r.error)); return refresh(); } ME = r.me; await loadPub().catch(() => {}); renderApp(); openTrip(); } catch (e) { toast('Нет сети'); } };
  if ($('#raceNo')) $('#raceNo').onclick = () => raceRespond(c.id, false, 'Вызов отклонён');
  if ($('#raceCancel')) $('#raceCancel').onclick = () => raceRespond(c.id, false, 'Вызов отменён');
  if ($('#raceNew')) $('#raceNew').onclick = openRace;
}
async function raceRespond(id, accept, msg) { try { const r = await rpc('zhol_challenge_respond', { p: SESSION.id, code: SESSION.code, id, accept }); toast(r.ok ? msg : errText(r.error)); refresh(); } catch (e) { toast('Нет сети'); } }
function openRace() {
  const here = ME.location;
  if (openCh(ME.id)) return toast('У тебя уже есть жарыс');
  const opp = PUB.players.filter(p => p.id !== ME.id && !p.trip && p.location === here && !openCh(p.id) && isTest(p.id) === isTest(ME.id));
  if (!opp.length) {
    return sheet(`<h2>⚔️ Жарыс</h2><p>Жарыс можно начать только с тем, кто сейчас в том же месте, что и ты (${esc(nname(here))}), и не в пути.</p><div class="muted">Где сейчас все:</div>${PUB.players.filter(p => p.id !== ME.id).map(p => `<div class="row"><div class="av">${p.avatar}</div><div class="grow"><b>${esc(p.name)}</b><small>${p.trip ? 'в пути → ' + esc(nname(p.trip.path.at(-1))) : '📍 ' + esc(nname(p.location))}</small></div></div>`).join('')}`);
  }
  sheet(`<h2>⚔️ Кого вызываем?</h2><div class="muted">Здесь (${esc(nname(here))}) сейчас:</div>` + opp.map(p => `<button class="opt" data-opp="${p.id}"><span class="i">${p.avatar}</span><span><b>${esc(p.name)}</b><small>${p.age} лет · ${Z.LEAGUES[p.league].name}</small></span></button>`).join(''));
  $('#sheet').querySelectorAll('[data-opp]').forEach(b => b.onclick = () => raceDest(b.dataset.opp));
}
function raceDest(opp) {
  const here = ME.location;
  const both = id => isOpen(id) && isOpen(id, pl(opp));
  const list = PUB.nodes.filter(n => n.id !== here && both(n.id)).map(n => ({ n, r: shortest(here, n.id, both) })).filter(x => x.r).sort((a, b) => (b.n.id === 'KOR') - (a.n.id === 'KOR') || a.r.km - b.r.km);
  sheet(`<h2>⚔️ Куда гонка?</h2><div class="muted">Вы с ${pl(opp).avatar} ${esc(pl(opp).name)} поедете по одной дороге.</div>` + list.map(({ n, r }) => `<button class="opt" data-to="${n.id}"><span class="i">${n.id === 'KOR' ? '🏡' : '🏁'}</span><span><b>${esc(n.name)}</b><small>${fmt(r.km)} км · ${r.path.map(nname).map(esc).join(' → ')}</small></span></button>`).join('') + `<button class="btn" style="width:100%;margin-top:12px" id="raceBack">← Назад</button>`);
  $('#raceBack').onclick = openRace;
  $('#sheet').querySelectorAll('[data-to]').forEach(b => b.onclick = () => raceTransport(opp, b.dataset.to));
}
function raceTransport(opp, to) {
  const O = pl(opp), r = shortest(ME.location, to, id => isOpen(id) && isOpen(id, O));
  sheet(`<h2>⚔️ На чём?</h2><div class="muted">Транспорт одинаковый для обоих. Младшим нужно меньше тапов, а скорость в км у всех честная.</div>` + RACE_TR.map(id => {
    const T = Z.TRANSPORT[id];
    const est = p => T.perTap ? `${fmt(Math.ceil(r.km / (T.perTap * mult(p.age))))} тапов` : `${Math.ceil(r.km / (T.perSec * mult(p.age)) / 60)} мин`;
    return `<button class="opt" data-tr="${id}"><span class="i">${T.icon}</span><span><b>${T.name}</b><small>${fmt(r.km)} км · тебе ≈ ${est(ME)}, ${esc(O.name)} ≈ ${est(O)}</small></span></button>`;
  }).join('') + `<div class="muted" style="margin-top:8px">Победитель: +15 🪙 и «Победа в жарысе». Второй, когда доедет: +3 🪙. Сойдёшь с дистанции — засчитается поражение.</div>`);
  $('#sheet').querySelectorAll('[data-tr]').forEach(b => b.onclick = async () => {
    b.disabled = true;
    try { const res = await rpc('zhol_challenge_create', { p: SESSION.id, code: SESSION.code, opponent: opp, path: r.path, transport: b.dataset.tr }); if (!res.ok) { b.disabled = false; return toast(errText(res.error)); } closeSheet(); toast(`Вызов отправлен ${O.name}! ⚔️`); refresh(); }
    catch (e) { b.disabled = false; toast('Нет сети'); }
  });
}
async function racePoll() {
  if (!T || !T.trip.challenge) return;
  try { await loadPub(); } catch (e) { return; }
  if (!T || !T.trip.challenge) return;
  const c = (PUB.challenges || []).find(x => x.id === +T.trip.challenge);
  if (c && c.winner && c.winner !== ME.id && !T.raceNotified) { T.raceNotified = true; toast(c.status === 'finished' ? `${pl(c.winner).name} финишировал(а) первым! Доезжай — +3 🪙 за участие` : 'Соперник сошёл с дистанции — победа твоя!', 3500); }
  drawTrip();
}
function raceTripHtml(done, total, pct) {
  if (!T || !T.trip.challenge) return { marker: '', stat: null };
  const c = (PUB.challenges || []).find(x => x.id === +T.trip.challenge); if (!c) return { marker: '', stat: null };
  const o = c.challenger === ME.id ? c.opponent : c.challenger, op = racePct(c, o);
  return { marker: op === null ? '' : `<div class="who opp" style="left:${op.toFixed(2)}%">${pl(o).avatar}</div>`, stat: `<div><b>${op === null ? '—' : Math.round(op) + '%'}</b><small>⚔️ ${esc(pl(o).name)} (ты ${Math.round(100 * done / total)}%)</small></div>` };
}

/* ---------- семейный чат ---------- */
const CHAT = { open: false, msgs: [], last: 0, mod: false, key: '', sig: '', timer: null, busy: false };
ERR.chat_slow = 'Не так быстро — подожди пару секунд'; ERR.chat_limit = 'На сегодня лимит 100 сообщений — продолжим завтра 🌙'; ERR.too_long = 'Слишком длинно — до 300 символов'; ERR.empty = 'Напиши что-нибудь'; ERR.not_allowed = 'Удалять может только админ';
function chatId() {
  if (vis('admin') && PIN) return { who: 'admin', uid: 'admin', code: PIN };
  if (vis('parent') && FAM) return { who: 'family', uid: FAM.id, code: FAM.code };
  if ((vis('app') || vis('trip')) && SESSION) return { who: 'kid', uid: SESSION.id, code: SESSION.code };
  return null;
}
const seenKey = c => 'zhol_chat_seen_' + c.who + '_' + c.uid;
function chatBadge(n) {
  for (const el of document.querySelectorAll('.chatnb')) { el.textContent = n > 9 ? '9+' : n; el.classList.toggle('hidden', !n); }
}
async function chatFetch(c, after = 0) { return rpc('zhol_chat', { who: c.who, uid: c.uid, code: c.code, after }); }
async function chatTick(force) {
  const c = chatId(); if (!c || CHAT.busy) return;
  if (!CHAT.open) {
    const seen = LS.get(seenKey(c), null);
    try { CHAT.busy = true; const r = await chatFetch(c, seen ?? 0); if (!r.ok) return;
      if (seen === null) { LS.set(seenKey(c), r.last); return chatBadge(0); }
      chatBadge(r.messages.filter(m => !m.mine && !m.deleted && m.kind !== 'system').length);
    } catch (e) {} finally { CHAT.busy = false; }
    return;
  }
  try { CHAT.busy = true; const r = await chatFetch(c, 0); if (r.ok) chatApply(r); } catch (e) {} finally { CHAT.busy = false; }
}
setInterval(() => { if (!CHAT.open && !vis('trip')) chatTick(); }, 20000);
function chatApply(r) {
  const c = chatId(); if (!c) return;
  CHAT.msgs = r.messages; CHAT.mod = r.mod; CHAT.ro = !!r.ro; document.querySelector('.chat-in').classList.toggle('hidden', CHAT.ro); CHAT.last = r.last; LS.set(seenKey(c), r.last); chatBadge(0);
  const sig = r.messages.map(m => m.id + (m.deleted ? 'd' : '')).join(',') + CHAT.mod;
  if (sig === CHAT.sig) return; CHAT.sig = sig; chatRender();
}
const ctime = s => { const d = new Date(s), t = d.toLocaleTimeString('ru-RU', { timeZone: 'Asia/Almaty', hour: '2-digit', minute: '2-digit' }); return new Date().toDateString() === d.toDateString() ? t : d.toLocaleDateString('ru-RU', { timeZone: 'Asia/Almaty', day: 'numeric', month: 'short' }) + ' ' + t; };
function chatRender() {
  const L = $('#chatList'), atBottom = L.scrollHeight - L.scrollTop - L.clientHeight < 80;
  const MS = CHAT.msgs.filter(m => !(m.kind === 'system' && m.deleted));
  L.innerHTML = MS.length ? MS.map(m => m.kind === 'system' ? `<div class="cm sys"><span>${esc(m.text)}</span><small>${ctime(m.at)}</small>${CHAT.mod ? `<button class="cdel" data-cdel="${m.id}" title="Удалить">🗑</button>` : ''}</div>` :
    `<div class="cm${m.mine ? ' mine' : ''}"><div class="cav" style="background:${m.color || (m.kind === 'admin' ? '#13283d' : '#f5a524')}">${m.avatar}</div><div class="cb"><div class="cn">${esc(m.name)} <small>${ctime(m.at)}</small>${CHAT.mod && !m.deleted ? `<button class="cdel" data-cdel="${m.id}" title="Удалить">🗑</button>` : ''}</div><div class="ct${m.deleted ? ' del' : ''}">${m.deleted ? 'сообщение удалено' : esc(m.text)}</div></div></div>`).join('')
    : '<div class="empty">Пока тихо. Напиши первым — привет всей семье! 👋</div>';
  L.querySelectorAll('[data-cdel]').forEach(b => b.onclick = () => chatDelete(+b.dataset.cdel));
  if (atBottom || !CHAT.rendered) L.scrollTop = L.scrollHeight; CHAT.rendered = true;
}
function chatOpen() {
  const c = chatId(); if (!c) return;
  closeSheet(); CHAT.open = true; CHAT.sig = ''; CHAT.rendered = false; $('#chat').classList.remove('hidden'); document.body.classList.add('chat-on');
  $('#chatSub').textContent = c.who === 'admin' ? 'Вы пишете как «Асет (админ)»' : c.who === 'family' ? FAMDATA?.family?.ro ? '👀 Только чтение (гостевой вход)' : 'Вы пишете как ' + (FAMDATA?.family?.all ? '«Асет»' : '«Родители · ' + (FAMDATA?.family?.name || '') + '»') : 'Вся семья: 8 детей, родители и Асет';
  $('#chatList').innerHTML = '<div class="empty">Загружаю…</div>'; chatFit();
  chatTick(true); clearInterval(CHAT.timer); CHAT.timer = setInterval(() => { if (CHAT.open) chatTick(); }, 5000);
  if (!matchMedia('(pointer:coarse)').matches) $('#chatIn').focus();
}
function chatClose() { if (!CHAT.open) return; CHAT.open = false; clearInterval(CHAT.timer); $('#chat').classList.add('hidden'); document.body.classList.remove('chat-on'); $('#chatIn').blur(); }
async function chatSend() {
  const c = chatId(), inp = $('#chatIn'), t = inp.value.trim(); if (!c || !t) return;
  if (t.length > 300) return toast(ERR.too_long);
  $('#chatSend').disabled = true;
  try { const r = await rpc('zhol_chat_send', { who: c.who, uid: c.uid, code: c.code, msg: t, after: 0 }); if (!r.ok) return toast(errText(r.error), 2500); inp.value = ''; chatCount(); CHAT.rendered = false; chatApply(r); $('#chatList').scrollTop = 1e9; }
  catch (e) { toast(e.offline ? 'Нет сети' : e.message); }
  finally { $('#chatSend').disabled = false; }
}
async function chatDelete(id) {
  const c = chatId(); if (!c || !confirm('Удалить это сообщение для всех?')) return;
  try { const r = await rpc('zhol_chat_delete', { who: c.who, uid: c.uid, code: c.code, id, after: 0 }); if (!r.ok) return toast(errText(r.error)); chatApply(r); toast('Удалено'); } catch (e) { toast(e.offline ? 'Нет сети' : e.message); }
}
function chatCount() { const n = $('#chatIn').value.length; $('#chatCnt').textContent = n > 250 ? (300 - n) : ''; $('#chatIn').style.height = 'auto'; $('#chatIn').style.height = Math.min(120, $('#chatIn').scrollHeight) + 'px'; }
function chatFit() { const vv = window.visualViewport, el = $('#chat'); if (!vv || !CHAT.open) return; el.style.height = vv.height + 'px'; el.style.top = vv.offsetTop + 'px'; }
if (window.visualViewport) { visualViewport.addEventListener('resize', () => { chatFit(); if (CHAT.open) $('#chatList').scrollTop = 1e9; }); visualViewport.addEventListener('scroll', chatFit); }
$('#chatIn').addEventListener('input', chatCount);
$('#chatIn').addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && !matchMedia('(pointer:coarse)').matches) { e.preventDefault(); chatSend(); } });
$('#chatSend').onclick = chatSend; $('#chatClose').onclick = chatClose;
for (const id of ['kidChat', 'famChat', 'adminChat']) $('#' + id).onclick = chatOpen;

/* ---------- ⭐ добрые дела: звёзды открывают новые края ---------- */
const DEED_ORDER = ['grade', 'read', 'book', 'home', 'good', 'sport'];
const DEED_HINT = { grade: 'Оценка 5 или 4 в школе сегодня', read: 'Сколько страниц прочитал(а) — 10 страниц = 1 ⭐', book: 'Дочитал(а) книгу до конца', home: 'Уборка, посуда, помощь маме и папе', good: 'Помог(ла) человеку: соседу, младшим, Ата и Әже…', sport: 'Тренировка, секция, зарядка' };
function deedPts(c, cat) { return cat === 'grade' ? `5 = ${c.p5} ⭐, 4 = ${c.p4} ⭐` : cat === 'read' ? `${c.per} стр. = 1 ⭐` : `${c.p} ⭐`; }
function deedTxt(r) {
  const it = r.item || {};
  const am = it.cat === 'grade' ? ` «${it.amount}»` : it.cat === 'read' ? `: ${it.amount} стр.` : '';
  return `${esc(it.e || '⭐')} ${esc(it.title || 'Доброе дело')}${am} · +${it.points} ⭐${it.comment ? ` — «${esc(it.comment)}»` : ''}`;
}
const nextReg = who => REGS().filter(R => !(who.unlocked || []).includes(R.id)).sort((a, b) => a.need - b.need)[0] || null;
let DEED_SEL = null;
function renderDeeds() {
  const el = $('#tab-deeds'); if (!el || !ME) return;
  const D = DEEDS(), cats = D.cats || {}, stars = +ME.stars || 0, nx = nextReg(ME), today = ME.deeds_today || {}, nToday = +ME.deeds_n_today || 0, maxDay = D.max_day || 10;
  const prev = REGS().filter(R => (ME.unlocked || []).includes(R.id)).reduce((m, R) => Math.max(m, +R.need), 0);
  let h = `<div class="card deeds-hero"><h3>⭐ Добрые дела — Жақсы істер</h3><div class="starbig">${stars} ⭐</div>`;
  h += nx ? `<div class="muted">До края <b>${nx.e || ''} ${esc(nx.n)}</b> (${regCities(nx.id).map(n => esc(n.name)).join(', ')}) — ещё <b>${Math.max(0, nx.need - stars)} ⭐</b></div><div class="bar"><i style="width:${Math.min(100, Math.max(0, 100 * (stars - prev) / Math.max(1, nx.need - prev)))}%"></i></div>`
    : `<div class="muted">Все края открыты — весь Казахстан твой! 🇰🇿</div>`;
  h += `<div class="muted" style="margin-top:6px">Делай хорошие дела в жизни — отмечай их здесь. Звёзды засчитываются, когда <b>родители подтвердят</b>. За звёзды открываются новые города на карте.</div></div>`;
  h += `<div class="card"><h3>✍️ Что я сделал(а) сегодня?</h3><div class="muted">Сегодня отмечено: ${nToday}/${maxDay}</div><div class="deedgrid">` + DEED_ORDER.filter(k => cats[k]).map(k => {
    const c = cats[k], used = +today[k] || 0, full = c.cap && used >= c.cap;
    return `<button class="deedbtn${DEED_SEL === k ? ' on' : ''}${full ? ' full' : ''}" data-deed="${k}"><span class="i">${esc(c.e)}</span><b>${esc(c.t)}</b><small>${deedPts(c, k)}${c.cap ? ` · сегодня ${used}/${c.cap} ⭐` : ''}</small></button>`;
  }).join('') + `</div><div id="deedForm"></div></div>`;
  const mine = REQS.filter(r => r.kind === 'deed');
  h += `<div class="card"><h3>🧾 Мои добрые дела</h3>${mine.length ? mine.map(r => `<div class="row"><div class="grow"><b>${deedTxt(r)}</b><small>${new Date(r.created_at).toLocaleDateString('ru-RU')}${r.note ? ' · ' + esc(r.note) : ''}</small></div>${stTag(r)}</div>`).join('') : '<div class="muted">Пока пусто — начни с одного доброго дела 🙂</div>'}</div>`;
  h += `<div class="card"><h3>🗺️ Края Казахстана</h3><div class="muted">Сначала открыт юг: Алматы, Кордай, Тараз, Астана и дороги между ними.</div>` + REGS().slice().sort((a, b) => a.need - b.need).map(R => {
    const on = (ME.unlocked || []).includes(R.id);
    return `<div class="row reg${on ? ' on' : ''}"><div class="av">${on ? R.e || '✅' : '🔒'}</div><div class="grow"><b>${esc(R.n)}</b><small>${regCities(R.id).map(n => esc(n.name)).join(', ')}</small></div>${on ? '<span class="tag ok">открыт</span>' : `<span class="tag">${R.need} ⭐</span>`}</div>`;
  }).join('') + `</div>`;
  el.innerHTML = h;
  el.querySelectorAll('[data-deed]').forEach(b => b.onclick = () => { DEED_SEL = b.dataset.deed; renderDeeds(); $('#deedForm').scrollIntoView({ behavior: 'smooth', block: 'nearest' }); });
  if (DEED_SEL && cats[DEED_SEL]) deedForm(DEED_SEL, cats[DEED_SEL]);
}
function deedForm(k, c) {
  let amount = k === 'grade' ? 5 : null;
  const f = $('#deedForm');
  f.innerHTML = `<div class="deedform"><b>${esc(c.e)} ${esc(c.t)}</b><div class="muted">${DEED_HINT[k] || ''}</div>
    ${k === 'grade' ? `<div class="inline" style="margin-top:8px"><button class="btn gradebtn on" data-g="5">5 — отлично (${c.p5} ⭐)</button><button class="btn gradebtn" data-g="4">4 — хорошо (${c.p4} ⭐)</button></div>` : ''}
    ${k === 'read' ? `<label>Сколько страниц?</label><input id="deedPages" type="number" inputmode="numeric" min="5" max="300" placeholder="например, 20">` : ''}
    <label>Пара слов (необязательно)</label><textarea id="deedCm" maxlength="200" rows="2" placeholder="${k === 'grade' ? 'по какому предмету?' : k === 'read' ? 'какая книга?' : 'что именно сделал(а)?'}"></textarea><small class="muted" id="deedCnt">0/200</small>
    <button class="big-btn teal" id="deedSend">Отправить родителям ⭐</button></div>`;
  f.querySelectorAll('[data-g]').forEach(b => b.onclick = () => { amount = +b.dataset.g; f.querySelectorAll('[data-g]').forEach(x => x.classList.toggle('on', x === b)); });
  $('#deedCm').oninput = () => $('#deedCnt').textContent = $('#deedCm').value.length + '/200';
  $('#deedSend').onclick = async () => {
    if (k === 'read') { amount = +$('#deedPages').value; if (!(amount >= 5 && amount <= 300)) return toast('Страниц — от 5 до 300'); }
    const btn = $('#deedSend'); btn.disabled = true;
    try {
      const r = await rpc('zhol_deed', { p: SESSION.id, code: SESSION.code, cat: k, amount, comment: $('#deedCm').value.slice(0, 200) });
      if (!r.ok) { btn.disabled = false; return toast(errText(r.error), 2600); }
      ME = r.me; REQS = r.requests; DEED_SEL = null; toast('Отправлено родителям! Жарайсың 👏', 2400); renderApp();
    } catch (e) { btn.disabled = false; toast(e.offline ? 'Нет сети' : e.message); }
  };
}
// праздник: открылся новый край
function unlockCheer() {
  if (!ME) return;
  const key = 'zhol_unl_' + ME.id, seen = LS.get(key, null), now = ME.unlocked || [];
  if (seen === null) { LS.set(key, now); return; }
  const fresh = now.filter(x => !seen.includes(x));
  if (!fresh.length) { if (now.length !== seen.length) LS.set(key, now); return; }
  if (T || !vis('app')) return;
  LS.set(key, now);
  const names = fresh.map(r => regCities(r).map(n => n.name).join(', ')).join(', ');
  sheet(`<div class="arr"><div style="font-size:56px">🔓✨</div><h2>Открыт новый край!</h2><p><b>${fresh.map(r => esc((regInfo(r).e || '') + ' ' + regInfo(r).n)).join(', ')}</b></p><p>Теперь можно поехать: ${esc(names)}. Жарайсың, ${esc(ME.name)}! ⭐</p><button class="big-btn teal" id="unlOk">Ура! Смотреть карту 🗺️</button></div>`);
  $('#unlOk').onclick = () => { closeSheet(); setTab('map'); };
}
// админ: очки и пороги
function deedAdminCard(cfg) {
  const D = cfg.deeds || { cats: {}, regions: [] }, C = D.cats || {};
  const inp = (k, f, v) => `<input class="dcf" data-k="${k}" data-f="${f}" type="number" min="0" value="${v ?? ''}" style="max-width:70px">`;
  return `<div class="card"><h3>⭐ Добрые дела: очки и пороги</h3><div class="muted">Звёзды дети получают после подтверждения родителей. «Лимит» — максимум звёзд по этому делу в день.</div>
    ${DEED_ORDER.filter(k => C[k]).map(k => { const c = C[k]; return `<div class="inline" style="margin-top:6px;flex-wrap:wrap"><b style="min-width:150px">${esc(c.e)} ${esc(c.t)}</b>${k === 'grade' ? `5 → ${inp(k, 'p5', c.p5)} 4 → ${inp(k, 'p4', c.p4)}` : k === 'read' ? `стр. за 1 ⭐ ${inp(k, 'per', c.per)}` : `⭐ ${inp(k, 'p', c.p)}`} лимит ${inp(k, 'cap', c.cap)}</div>`; }).join('')}
    <label>Максимум дел в день на ребёнка</label><input id="dMax" type="number" min="1" max="30" value="${D.max_day || 10}">
    <h4 style="margin:12px 0 4px">Пороги краёв (⭐ всего)</h4>${(D.regions || []).map(R => `<div class="inline" style="margin-top:4px"><span style="flex:1">${R.e || ''} ${esc(R.n)} <small class="muted">${regCities(R.id).map(n => esc(n.name)).join(', ')}</small></span><input class="drn" data-r="${R.id}" type="number" min="0" value="${R.need}" style="max-width:80px"></div>`).join('')}
    <button class="big-btn teal" id="dSave">Сохранить</button></div>`;
}
function bindDeedAdmin(cfg) {
  const b = $('#dSave'); if (!b) return;
  b.onclick = () => {
    const D = JSON.parse(JSON.stringify(cfg.deeds || { cats: {}, regions: [] }));
    document.querySelectorAll('.dcf').forEach(i => { const v = i.value === '' ? null : Math.max(0, Math.round(+i.value)); if (v !== null) D.cats[i.dataset.k][i.dataset.f] = i.dataset.f === 'per' ? Math.max(1, v) : v; });
    document.querySelectorAll('.drn').forEach(i => { const R = D.regions.find(r => r.id === i.dataset.r); if (R) R.need = Math.max(0, Math.round(+i.value || 0)); });
    D.max_day = Math.min(30, Math.max(1, Math.round(+$('#dMax').value || 10)));
    adm('set_config', { config: { deeds: D } });
  };
}

/* ---------- навигация: Домой и кнопка «назад» ---------- */
function setTab(t) {
  TAB = t; $('#tabs').querySelectorAll('button').forEach(x => x.classList.toggle('on', x.dataset.tab === t));
  for (const k of ['map', 'family', 'ach', 'bank', 'deeds']) $('#tab-' + k).classList.toggle('hidden', k !== t);
  window.scrollTo(0, 0);
}
const vis = id => !$('#' + id).classList.contains('hidden');
function goHome() {
  closeSheet(); chatClose();
  if (T) { closeTrip(true); setTab('map'); toast('Поездка на паузе — продолжишь с карты'); return; }
  if (vis('admin')) { PIN = null; ADMIN = null; }
  if (ME && SESSION) { show('app'); setTab('map'); renderApp(); }
  else if (FAMDATA && LS.get('zhol_mode', '') === 'family') { show('parent'); }
  else { show('login'); renderKids(); }
}
let lastBack = 0;
function onBack() {
  if (!$('#modal').classList.contains('hidden')) { if (SHEET_LOCKED) goHome(); else closeSheet(); return true; }
  if (CHAT.open) { chatClose(); return true; }
  if (vis('trip') || vis('admin')) { goHome(); return true; }
  if (vis('app') && TAB !== 'map') { setTab('map'); return true; }
  const now = Date.now();
  if (now - lastBack < 2500) return false;
  lastBack = now; toast('Нажмите «назад» ещё раз, чтобы выйти из игры', 2500); return true;
}
history.replaceState({ z: 'root' }, '');
history.pushState({ z: 'guard' }, '');
window.addEventListener('popstate', () => {
  if (onBack()) history.pushState({ z: 'guard' }, '');
  else history.back();
});

if (LS.get('zhol_test', false)) window.__zhol = () => ({ ME, T });
boot();
})();
