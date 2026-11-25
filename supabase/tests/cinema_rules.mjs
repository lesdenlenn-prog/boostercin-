// RÈGLES DE POSE : compare celles du client (cineDoor / cineCheck, extraites d'index.html) à cine_build_room, sur des
// placements tirés au hasard (3 sur 4 collés au bâtiment), dans une transaction annulée : rien ne reste. Nécessite `pg`.
// usage : node supabase/tests/cinema_rules.mjs .env index.html [essais]
import fs from 'node:fs';
import pg from 'pg';
const env = Object.fromEntries(fs.readFileSync(process.argv[2], 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l)).map(l => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const html = fs.readFileSync(process.argv[3], 'utf8');
const N = +(process.argv[4] || 400);
const a = html.indexOf('function cineDoor('), b = html.indexOf('// Cases libres collées');
if(a < 0 || b < 0) throw new Error('règles du client introuvables');
let cpRooms = [], cpGrid = {cols:40, rows:40};
const client = new Function('ctx', `let cpRooms, cpGrid; ${html.slice(a, b)}; return (rooms, grid, n) => { cpRooms = rooms; cpGrid = grid; return cineCheck(n); };`)();

const c = new pg.Client({ connectionString: env.SUPABASE_DB_URL, ssl: { rejectUnauthorized: false } });
const UID = '11111111-2222-4333-8444-' + Date.now().toString(16).padStart(12, '0').slice(-12);
const as = async (fn, args = []) => {
  await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: UID, role: 'authenticated' })]);
  await c.query('set local role authenticated');
  const r = await c.query(`select public.${fn}(${args.map((_, i) => '$' + (i + 1)).join(',')}) as j`, args);
  await c.query('reset role');
  return r.rows[0].j;
};
let seed = 12345; const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
let ok = 0, ko = 0, valid = 0;
try {
  await c.connect(); await c.query('begin');
  await c.query(`insert into auth.users (id, aud, role, email, instance_id, created_at, updated_at)
                 values ($1, 'authenticated', 'authenticated', $2, '00000000-0000-0000-0000-000000000000', now(), now())`, [UID, 'rules-' + UID.slice(-6) + '@example.invalid']);
  await c.query('update public.profiles set is_admin = true, tickets = 10000000 where id = $1', [UID]);
  await as('cine_get_state');
  for (const [t, s, x, y, r] of [['projection','S',14,25,false], ['arcade','S',27,33,true], ['toilets','S',14,21,false], ['corridor','M',9,31,false], ['snacks','M',8,27,true]]) {
    const j = await as('cine_build_room', [t, s, x, y, r]); if (!j.ok) throw new Error('préparation : ' + j.message);
    await as('cine_admin_finish_build');
  }
  const st = await as('cine_get_state');
  const rooms = st.rooms.map(r => ({id:r.id, type:r.type, x:r.x, y:r.y, w:r.w, h:r.h, built:r.built}));
  const types = st.offers;
  for (let i = 0; i < N; i++) {
    const o = types[Math.floor(rnd() * types.length)], rot = rnd() < .5;
    const w = rot ? o.h : o.w, h = rot ? o.w : o.h;
    let x = 3 + Math.floor(rnd() * 32), y = 14 + Math.floor(rnd() * 26);
    if (i % 4) {                     // 3 essais sur 4 : collé à une pièce, d'un côté au hasard, décalé au hasard
      const R = rooms[Math.floor(rnd() * rooms.length)], side = Math.floor(rnd() * 4);
      if (side === 0) { x = R.x + R.w; y = R.y - h + 1 + Math.floor(rnd() * (R.h + h - 1)); }
      if (side === 1) { x = R.x - w;   y = R.y - h + 1 + Math.floor(rnd() * (R.h + h - 1)); }
      if (side === 2) { y = R.y + R.h; x = R.x - w + 1 + Math.floor(rnd() * (R.w + w - 1)); }
      if (side === 3) { y = R.y - h;   x = R.x - w + 1 + Math.floor(rnd() * (R.w + w - 1)); }
    }
    const cl = client(rooms, {cols:+st.grid.cols, rows:+st.grid.rows}, {x, y, w, h});
    await c.query('savepoint t');
    const j = await as('cine_build_room', [o.type, o.size, x, y, rot]);
    await c.query('rollback to savepoint t');
    let same = cl.ok === j.ok && (j.ok || cl.reason === j.reason);
    if (same && j.ok) {
      valid++;
      const nr = j.state.rooms.find(r => r.id === j.room_id), d = nr.doors[0];
      same = d.side === cl.door.side && d.at === cl.door.at && d.len === cl.door.len;
    }
    same ? ok++ : ko++;
    if (!same && ko <= 5) console.log('ÉCART', o.type, o.size, x, y, rot, 'client', JSON.stringify(cl), 'serveur', j.ok ? JSON.stringify(j.state.rooms.find(r => r.id === j.room_id).doors) : j.reason);
  }
} catch (e) { ko++; console.log('ERREUR :', String(e.message).split(env.SUPABASE_DB_URL).join('[DB_URL]')); }
finally { await c.query('rollback').catch(() => {}); await c.end(); console.log(`${ok} identiques (dont ${valid} places valides, porte comparée), ${ko} écarts — transaction annulée.`); }
