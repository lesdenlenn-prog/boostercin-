-- =====================================================================
-- TESTS MANUELS de get_booster_state() / open_booster() — à coller BLOC PAR BLOC dans le SQL Editor.
-- Avant : créer un joueur de test (Authentication → Users → Add user → Create new user, « Auto Confirm User » coché),
-- puis remplacer partout 00000000-0000-0000-0000-000000000000 par son UID (Ctrl+H).
-- Les blocs « joueur » simulent sa connexion : set_config place son identifiant dans le JWT lu par auth.uid().
-- Après les tests : supprimer le joueur dans Authentication → Users (profil, collection et ouvertures partent avec).
-- =====================================================================


-- ---------- 0. Le profil a bien été créé par le déclencheur (attendu : 1 ligne, energy_n = 6, reels = gems = 0)
select id, energy_n, energy_t, reels, gems, boosters_opened from public.profiles
 where id = '00000000-0000-0000-0000-000000000000';


-- ---------- 1. État de départ (attendu : energy.n = 6, next_free_at = null, price.free = true, cost_reels = 0)
select public.get_booster_state()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 2. Ouvrir un booster gratuit
-- attendu : ok = true, payment = "free", 5 cartes de la moins rare à la plus rare, la 5e jamais "common",
--           state.energy.n = 5, ms_to_next ≈ 14 400 000 (4 h), boosters_opened = 1
select public.open_booster()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 3. Plus de gratuit, 2 h 30 restantes, 0 bobine, 0 gemme (préparation en admin)
update public.profiles set energy_n = 0, energy_t = now() - interval '1 hour 30 minutes', reels = 0, gems = 0
 where id = '00000000-0000-0000-0000-000000000000';

-- attendu : ok = false, reason = "insufficient_funds", 2 h 30 → 3 heures entamées = 45 bobines, il manque 45 → 18 gemmes
select public.open_booster()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 4. 30 bobines + 20 gemmes : il manque 15 bobines = 3 lots = 6 gemmes
update public.profiles set reels = 30, gems = 20 where id = '00000000-0000-0000-0000-000000000000';

-- 4a. sans accord : ok = false, reason = "need_gems", rien n'est débité
select public.open_booster()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 4b. avec accord : ok = true, payment = "reels", cost_reels = 45, cost_gems = 6,
--     state.reels = 0, state.gems = 14, energy.n = 0, ms_to_next ≈ 14 400 000 (cycle de 4 h relancé), cost_reels = 60
select public.open_booster(true)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 5. Paiement direct en bobines (cycle tout juste relancé : 4 h = 60 bobines)
update public.profiles set reels = 100 where id = '00000000-0000-0000-0000-000000000000';

-- attendu : ok = true, cost_reels = 60, cost_gems = 0, state.reels = 40, gems inchangées (14)
select public.open_booster()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 6. Recharge pendant l'absence : 2 boosters, compteur parti il y a 9 h → +2 (8 h), 1 h d'avance gardée
update public.profiles set energy_n = 2, energy_t = now() - interval '9 hours' where id = '00000000-0000-0000-0000-000000000000';

-- attendu : energy.n = 4, ms_to_next ≈ 10 800 000 (3 h), price.free = true
select public.get_booster_state()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- plein : energy_n = 5 il y a 5 h → 6, next_free_at = null, ms_to_next = 0
update public.profiles set energy_n = 5, energy_t = now() - interval '5 hours' where id = '00000000-0000-0000-0000-000000000000';
select public.get_booster_state()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 7. Collection et historique (attendu : somme des count = 15 sur 3 boosters, rareté/rang du tirage ;
--               3 lignes openings : free, reels avec 6 gemmes, reels sans gemme)
select c.film_id, f.title, c.count, c.rarity, c.rank, c.first_obtained_at
  from public.collection c join public.films f on f.id = c.film_id
 where c.user_id = '00000000-0000-0000-0000-000000000000'
 order by c.rarity desc, c.rank;

select id, payment, cost_reels, cost_gems, demo, film_ids, rarities, created_at
  from public.openings where user_id = '00000000-0000-0000-0000-000000000000' order by id;


-- ---------- 8. Mode démo (admin) : cotes élevées, rien n'entre dans la collection
update public.profiles set is_admin = true, demo_mode = true where id = '00000000-0000-0000-0000-000000000000';

-- attendu : ok = true, demo = true, beaucoup d'epic/legendary/ultra ; relancer le bloc 7 : collection inchangée,
--           une ligne openings avec demo = true ; boosters_opened augmente quand même
select public.open_booster()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

update public.profiles set demo_mode = false where id = '00000000-0000-0000-0000-000000000000';


-- ---------- 9. Probabilités sur 200 000 tirages (bloc admin, ~2 s)
-- attendu : ultra ≈ 0,05 %, legendary ≈ 0,5 %, epic ≈ 2,5 %, rare ≈ 9 %, uncommon ≈ 28 %, common ≈ 59,95 %
select r as rarete, count(*) as tirages, round(100.0 * count(*) / 200000, 3) as pourcent
  from (select public._pick_rarity(false, false) as r from generate_series(1, 200000)) s
 group by r order by r desc;

-- 5e carte (sans Commune) : jamais "common", cotes renormalisées (uncommon ≈ 69,9 %)
select r as rarete, count(*) as tirages, round(100.0 * count(*) / 200000, 3) as pourcent
  from (select public._pick_rarity(false, true) as r from generate_series(1, 200000)) s
 group by r order by r desc;


-- ---------- 10. Sécurité : choisir le rôle en bas à droite du SQL Editor (au lieu de « postgres »), puis lancer
-- Rôle « anon »                         → select public.open_booster();                       : permission denied
-- Rôle « authenticated » + joueur test  → update public.profiles set reels = 99999;           : permission denied
--                                       → insert into public.collection (user_id, film_id, rarity, rank)
--                                         values (auth.uid(), 550, 'ultra', 1);                : permission denied
--                                       → select public._pick_rarity(false, false);           : permission denied
--                                       → select public.get_booster_state();                  : fonctionne
