// TESTS AUTOMATIQUES du Cinéma sur le plan (cine_*, étape J1). Tout se passe dans UNE transaction annulée à la fin
// (rollback) : joueur de test fictif inséré dans auth.users, appels en tant que lui, rien ne reste dans la base.
// Aucun secret affiché (SUPABASE_DB_URL lue dans .env). Nécessite le paquet `pg` (npm i pg, hors du dépôt).
// usage : node supabase/tests/cinema_rooms.mjs .env <migration.sql | ->
//   avec une migration : l'exécute d'abord dans la transaction (test avant db push) ; « - » : schéma déjà appliqué.
import fs from 'node:fs';
import pg from 'pg';
const env = Object.fromEntries(fs.readFileSync(process.argv[2], 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l)).map(l => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const mask = s => String(s).split(env.SUPABASE_DB_URL).join('[DB_URL]');
const c = new pg.Client({ connectionString: env.SUPABASE_DB_URL, ssl: { rejectUnauthorized: false } });
let ok = 0, ko = 0;
const check = (name, cond, info = '') => { cond ? ok++ : ko++; console.log((cond ? 'OK  ' : 'RATÉ') + ' ' + name + (cond ? '' : '  → ' + info)); };
const UID = '11111111-2222-4333-8444-' + Date.now().toString(16).padStart(12, '0').slice(-12);
async function as(fn, args = []) {            // appel en tant que joueur de test
  await c.query('savepoint sp');
  try {
    await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: UID, role: 'authenticated' })]);
    await c.query('set local role authenticated');
    const r = await c.query(`select public.${fn}(${args.map((_, i) => '$' + (i + 1)).join(',')}) as j`, args);
    await c.query('reset role'); await c.query('release savepoint sp');
    return r.rows[0].j;
  } catch (e) { await c.query('rollback to savepoint sp'); await c.query('reset role'); return { error: e.message }; }
}
const sql = (q, a) => c.query(q, a);
const room = (st, type) => st.rooms.filter(r => r.type === type);
const offer = (st, t, s) => st.offers.find(o => o.type === t && o.size === s);
try {
  await c.connect();
  await sql('begin');
  if (process.argv[3] !== '-') { await sql(fs.readFileSync(process.argv[3], 'utf8')); console.log('migration exécutée (dans la transaction)'); }
  await sql(`insert into auth.users (id, aud, role, email, instance_id, created_at, updated_at)
             values ($1, 'authenticated', 'authenticated', $2, '00000000-0000-0000-0000-000000000000', now(), now())`, [UID, 'test-j1-' + UID.slice(-6) + '@example.invalid']);

  // 0. équilibrage
  const cnt = (await sql(`select (select count(*) from cine_params)::int p, (select count(*) from cine_room_types)::int t, (select count(*) from cine_box_office)::int b`)).rows[0];
  check('0. équilibrage : 10 paramètres, 15 tailles, 10 niveaux de guichet', cnt.p === 10 && cnt.t === 15 && cnt.b === 10, JSON.stringify(cnt));

  // 1. premier passage : base
  let st = await as('cine_get_state');
  const hall = room(st, 'hall')[0], box = room(st, 'box_office')[0];
  check('1. base : couloir (13,30 6×10) + guichet (19,32 8×7), taux 0, grille 40×40',
    st.rooms.length === 2 && hall.x === 13 && hall.y === 30 && hall.w === 6 && hall.h === 10 && box.x === 19 && box.y === 32 && box.w === 8 && box.h === 7
    && +st.rate === 0 && st.grid.cols == 40 && st.build === null, JSON.stringify(st).slice(0, 300));
  check('1b. portes de la base reliées par id', hall.doors[1].to === box.id && box.doors[0].to === hall.id, JSON.stringify([hall.doors, box.doors]));
  check('1c. 1re salle de projection offerte et immédiate', offer(st, 'projection', 'S').cost === 0 && offer(st, 'projection', 'S').minutes === 0, JSON.stringify(offer(st, 'projection', 'S')));

  // 2. 1re salle de projection au nord du couloir
  let r = await as('cine_build_room', ['projection', 'S', 14, 25, false]);
  const p1 = r.ok && room(r.state, 'projection')[0];
  check('2. salle offerte posée au nord, construite tout de suite, taux 5 (20 × 0,25)', r.ok && r.cost === 0 && p1.built && +r.state.rate === 5 && r.state.build === null, JSON.stringify(r).slice(0, 300));
  check('2b. porte nord/sud créée des deux côtés', p1 && p1.doors[0].side === 's' && p1.doors[0].at === 1 && p1.doors[0].len === 2 && p1.doors[0].to === hall.id
    && room(r.state, 'hall')[0].doors.some(d => d.side === 'n' && d.at === 2 && d.to === p1.id), JSON.stringify([p1 && p1.doors, room(r.state, 'hall')[0].doors]));
  check('2c. la 2e salle coûte 20 cases × 20 × 1,5 = 600', offer(r.state, 'projection', 'S').cost === 600, offer(r.state, 'projection', 'S').cost);

  // 3. refus
  r = await as('cine_build_room', ['projection', 'S', 9, 20, false]);
  check('3a. pas assez de billets (après la place libre)', r.reason === 'no_door' || r.reason === 'insufficient_tickets', JSON.stringify(r).slice(0, 120));
  r = await as('cine_build_room', ['projection', 'S', 14, 27, false]);
  check('3b. chevauchement refusé', r.reason === 'overlap', r.reason || r.error);
  r = await as('cine_build_room', ['projection', 'S', 38, 10, false]);
  check('3c. hors de la grille refusé', r.reason === 'out_of_grid', r.reason || r.error);
  r = await as('cine_build_room', ['projection', 'S', 0, 0, false]);
  check('3d. pièce isolée refusée (pas de porte)', r.reason === 'no_door', r.reason || r.error);
  r = await as('cine_build_room', ['projection', 'S', 9, 25, false]);
  check('3e. contact par un coin seulement refusé', r.reason === 'no_door', r.reason || r.error);
  r = await as('cine_build_room', ['projection', 'S', 10, 30, false]);
  check('3f. mur commun trop haut placé (dans le mur du fond) : sans billets → refus insufficient ou no_door', !!r.reason, JSON.stringify(r).slice(0, 120));
  r = await as('cine_build_room', ['projection', 'S', 9, 31, false]);
  check('3g. collée à l\'ouest du couloir : place valide mais 600 billets manquants', r.reason === 'insufficient_tickets' && r.message === 'Il te manque 600 billets.', JSON.stringify(r).slice(0, 160));

  // 4. outils admin
  r = await as('cine_admin_add_tickets', [10000]);
  check('4a. outil admin refusé à un joueur', /admin/.test(r.error || ''), JSON.stringify(r).slice(0, 120));
  await sql('update public.profiles set is_admin = true where id = $1', [UID]);
  r = await as('cine_admin_add_tickets', [10000]);
  check('4b. admin : +10 000 billets', r.tickets === 10000, JSON.stringify(r).slice(0, 120));

  // 5. arcade tournée, à l'est du guichet (mur vertical, porte d'1 case)
  r = await as('cine_build_room', ['arcade', 'S', 27, 33, true]);
  const arc = r.ok && room(r.state, 'arcade')[0];
  check('5. arcade 5×4 lancée : 400 billets, chantier 15 min, gemmes = 2', r.ok && r.cost === 400 && arc.w === 5 && arc.h === 4 && !arc.built
    && r.state.build.kind === 'room' && r.state.build.room_id === arc.id && r.state.build.gem_price === 2 && r.state.tickets === 9600, JSON.stringify(r).slice(0, 300));
  check('5b. porte est/ouest', arc && arc.doors[0].side === 'w' && arc.doors[0].len === 1 && room(r.state, 'box_office')[0].doors.some(d => d.side === 'e' && d.to === arc.id), JSON.stringify(arc && arc.doors));
  r = await as('cine_build_room', ['corridor', 'S', 14, 21, false]);
  check('5c. 2e chantier refusé', r.reason === 'busy', r.reason || r.error);
  r = await as('cine_upgrade_box_office');
  check('5d. guichet refusé pendant un chantier', r.reason === 'busy', r.reason || r.error);
  r = await as('cine_finish_with_gems', [1]);
  check('5e. prix des gemmes qui a augmenté refusé', r.reason === 'price_changed', r.reason || r.error);
  r = await as('cine_finish_with_gems', [2]);
  check('5f. pas assez de gemmes', r.reason === 'insufficient_gems', r.reason || r.error);
  await sql('update public.profiles set gems = 5 where id = $1', [UID]);
  r = await as('cine_finish_with_gems', [2]);
  const arc2 = r.ok && room(r.state, 'arcade')[0];
  check('5g. fini en gemmes : 2 gemmes, arcade ouverte avec 1 machine en (1,2), taux 15', r.ok && r.cost_gems === 2 && r.state.gems === 3 && arc2.built
    && arc2.machines.length === 1 && arc2.machines[0].x === 1 && arc2.machines[0].y === 2 && +r.state.rate === 15 && r.state.build === null, JSON.stringify(r).slice(0, 300));

  // 6. machines
  check('6a. 1re machine achetée : 100 billets', r.state.machine_price === 100, r.state.machine_price);
  r = await as('cine_buy_machine', [arc.id, 2, 2]);
  check('6b. machine achetée en (2,2), taux 25, prix suivant 150', r.ok && r.cost === 100 && +r.state.rate === 25 && r.state.machine_price === 150, JSON.stringify(r).slice(0, 200));
  r = await as('cine_buy_machine', [arc.id, 2, 2]);
  check('6c. case occupée refusée', r.reason === 'cell_taken', r.reason || r.error);
  r = await as('cine_buy_machine', [arc.id, 0, 2]);
  check('6d. case hors du sol refusée', r.reason === 'bad_cell', r.reason || r.error);
  const mid = room(r.state, 'arcade')[0].machines[1].id;
  r = await as('cine_move_machine', [mid, 3, 2]);
  check('6e. machine déplacée en (3,2)', r.ok && room(r.state, 'arcade')[0].machines.some(m => m.id === mid && m.x === 3), JSON.stringify(r).slice(0, 200));
  r = await as('cine_move_machine', [mid, 1, 2]);
  check('6f. déplacement sur une machine refusé', r.reason === 'cell_taken', r.reason || r.error);

  // 7. film projeté (rare × 1,6)
  const film = (await sql(`select id from public.films order by id limit 1`)).rows[0].id;
  await sql(`insert into public.collection (user_id, film_id, rarity, rank) values ($1, $2, 'rare', 100)`, [UID, film]);
  r = await as('cine_set_film', [p1.id, film]);
  check('7a. film rare : taux 20 × 1,6 + 20 = 52', r.ok && +r.state.rate === 52 && room(r.state, 'projection')[0].film.rarity === 'rare', JSON.stringify(r).slice(0, 200));
  r = await as('cine_set_film', [arc.id, film]);
  check('7b. film dans une arcade refusé', /projection/.test(r.error || ''), JSON.stringify(r).slice(0, 120));

  // 8. toilettes : +5 %
  r = await as('cine_build_room', ['toilets', 'S', 14, 21, false]);
  check('8a. toilettes lancées : 160 billets', r.ok && r.cost === 160, JSON.stringify(r).slice(0, 200));
  r = await as('cine_admin_finish_build');
  check('8b. toilettes ouvertes : taux 52 × 1,05 = 54,6', +r.rate === 54.6 && r.bonus_pct == 5, JSON.stringify([r.rate, r.bonus_pct, r.error]));

  // 9. caisse et plafond 12 h
  await sql(`update public.cine_states set accrue_from = now() - interval '20 hours', last_collect_at = now() - interval '20 hours', banked = 0 where user_id = $1`, [UID]);
  st = await as('cine_get_state');
  check('9a. 20 h écoulées → 12 h produites : 655', st.pending === 655, st.pending);
  r = await as('cine_collect');
  check('9b. récolte : 655 billets, caisse vide', r.ok && r.collected === 655 && r.state.pending === 0, JSON.stringify(r).slice(0, 160));

  // 10. guichet
  r = await as('cine_upgrade_box_office');
  check('10a. guichet niveau 1 lancé : 300 billets', r.ok && r.cost === 300 && r.state.build.kind === 'box_office' && r.state.build.level === 1, JSON.stringify(r).slice(0, 200));
  r = await as('cine_admin_finish_build');
  check('10b. guichet niveau 1 : bonus 15 %, taux 52 × 1,15 = 59,8', r.box_office.level === 1 && +r.rate === 59.8, JSON.stringify([r.box_office, r.rate]));

  // 11. remise à la base (admin) ; ancien modèle toujours utilisable
  const before = r.tickets;
  r = await as('cine_admin_reset');
  check('11a. remise à la base : 2 pièces, billets conservés', r.rooms.length === 2 && r.tickets === before && offer(r, 'projection', 'S').cost === 0, JSON.stringify(r).slice(0, 200));
  r = await as('get_cinema_state');
  check('11b. ancien get_cinema_state toujours fonctionnel', !r.error && Array.isArray(r.screens), JSON.stringify(r).slice(0, 120));
  await sql('savepoint z');
  await sql(`select set_config('request.jwt.claims', '{"role":"authenticated"}', true)`);
  await sql('set local role authenticated');
  r = await c.query(`select public.cine_get_state()`).catch(e => ({ error: e.message }));
  check('11c. jeton sans utilisateur : refus « Connexion requise »', /Connexion/.test(r.error || ''), JSON.stringify(r).slice(0, 120));
  await sql('rollback to savepoint z'); await sql('reset role');
  await sql('set local role anon');
  r = await c.query(`select public.cine_build_room('projection','S',14,25,false)`).catch(e => ({ error: e.message }));
  check('11d. visiteur anonyme (anon) : exécution interdite', /permission denied/.test(r.error || ''), JSON.stringify(r).slice(0, 120));
  await sql('rollback to savepoint z'); await sql('reset role');
  r = await c.query(`select public._cine_settle($1, now())`, [UID]).then(() => ({}), e => ({ error: e.message }));
  await sql('rollback to savepoint z');
  await sql('set local role authenticated');
  r = await c.query(`select public._cine_settle($1, now())`, [UID]).catch(e => ({ error: e.message }));
  check('11e. fonction interne interdite aux joueurs', /permission denied/.test(r.error || ''), JSON.stringify(r).slice(0, 120));
  await sql('rollback to savepoint z'); await sql('reset role');
  r = await c.query(`select count(*)::int n from public.cine_rooms`);
  await sql('set local role authenticated');
  await sql(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: '00000000-0000-4000-8000-000000000000', role: 'authenticated' })]);
  const seen = (await c.query(`select count(*)::int n from public.cine_rooms`)).rows[0].n;
  check('11f. RLS : un autre joueur ne voit pas les pièces du joueur de test', seen === 0, seen);
  const w = await c.query(`update public.cine_rooms set x = 0`).catch(e => ({ error: e.message }));
  check('11g. écriture directe des pièces interdite', /permission denied/.test(w.error || ''), JSON.stringify(w).slice(0, 120));
} catch (e) { ko++; console.log('ERREUR :', mask(e.message)); }
finally { await c.query('rollback').catch(() => {}); await c.end(); console.log(`\n${ok} réussis, ${ko} ratés — transaction annulée, rien n'a été écrit.`); }
