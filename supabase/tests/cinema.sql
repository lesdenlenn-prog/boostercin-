-- =====================================================================
-- TESTS MANUELS du mode Cinéma — à coller BLOC PAR BLOC dans le SQL Editor.
-- Même préparation que open_booster.sql : joueur de test (Authentication → Users → Add user, « Auto Confirm User »),
-- puis remplacer partout 00000000-0000-0000-0000-000000000000 par son UID (Ctrl+H). À supprimer à la fin.
-- Les blocs « update » préparent une situation (ex. reculer l'horloge du cinéma) en tant qu'admin du SQL Editor.
-- Ne pas commiter ce fichier avec un vrai UID.
-- =====================================================================


-- ---------- 0. Équilibrage en place (attendu : 55 niveaux, 3 paramètres, 6 raretés)
select (select count(*) from public.cinema_levels) as niveaux,
       (select count(*) from public.cinema_params) as params,
       (select count(*) from public.cinema_rarity) as raretes;


-- ---------- 1. Premier passage : le cinéma est créé (attendu : tickets = 0, rate = 5 (salle 1 vide = 20 × 0,25),
--               screens = 1 salle sans film, levels.screen = 1, build = null)
select public.get_cinema_state()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 2. Un booster, puis le film le plus rare dans la salle 1
select public.open_booster()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- attendu : ok = true, rate = 20 × multiplicateur de sa rareté (Commune 20, Peu commune 25, Rare 32, Épique 44…),
--           screens[0] avec titre, affiche et rareté
select public.set_screening(1, (select film_id from public.collection
                                 where user_id = '00000000-0000-0000-0000-000000000000' order by rarity desc limit 1))
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 3. Caisse : 2 h écoulées depuis la dernière récolte (attendu : pending = 2 × rate)
update public.cinemas set accrue_from = now() - interval '2 hours', last_collect_at = now() - interval '2 hours', banked = 0
 where user_id = '00000000-0000-0000-0000-000000000000';

select public.get_cinema_state()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 4. Plafond : 20 h écoulées → seulement 12 h produites (attendu : pending = 12 × rate, full_at dans le passé)
update public.cinemas set accrue_from = now() - interval '20 hours', last_collect_at = now() - interval '20 hours', banked = 0
 where user_id = '00000000-0000-0000-0000-000000000000';

select public.get_cinema_state()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 5. Récolter (attendu : collected = 12 × rate, state.tickets = collected, state.pending = 0, full_at = maintenant + 12 h)
select public.collect_cash()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 6. Constructions : refus puis lancement
-- 6a. attendu : ok = false, reason = "locked" (« Disponible à partir de 2 salles. »)
select public.start_build('arcade')
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 6b. 100 billets : attendu : reason = "insufficient_tickets", « Il te manque 50 billets. »
update public.profiles set tickets = 100, gems = 0 where id = '00000000-0000-0000-0000-000000000000';

select public.start_build('screen')
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 6c. 1 000 billets : attendu : ok = true, cost = 150, tickets = 850, build = {kind "screen", level 2, ms_left ≈ 1 800 000, gem_price 3}
update public.profiles set tickets = 1000 where id = '00000000-0000-0000-0000-000000000000';

select public.start_build('screen')
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 6d. attendu : reason = "busy" (une seule construction à la fois)
select public.start_build('box_office')
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 7. « Terminer maintenant » en gemmes
-- 7a. prix affiché trop bas : attendu : reason = "price_changed", « Le prix est maintenant de 3 gemmes. »
select public.finish_build_with_gems(1)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 7b. 0 gemme : attendu : reason = "insufficient_gems"
select public.finish_build_with_gems(3)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 7c. 10 gemmes : attendu : ok = true, cost_gems = 3, gems = 7, levels.screen = 2, build = null, rate = ancien + 5
update public.profiles set gems = 10 where id = '00000000-0000-0000-0000-000000000000';

select public.finish_build_with_gems(3)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 8. Taux qui change pendant l'absence : salle 3 lancée, terminée il y a 30 min, dernière récolte il y a 1 h
select public.start_build('screen')
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

update public.cinemas
   set accrue_from = now() - interval '1 hour', last_collect_at = now() - interval '1 hour', banked = 0,
       build_started_at = now() - interval '1 hour', build_ends_at = now() - interval '30 minutes'
 where user_id = '00000000-0000-0000-0000-000000000000';

-- attendu : levels.screen = 3, build = null, rate = ancien + 6,25 (salle 3 vide : 25 × 0,25),
--           pending_exact = ancien × 0,5 + nouveau × 0,5 (ex. 37 et 43,25 → 40,125)
select public.get_cinema_state()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 9. Films dans les salles
-- 9a. le même film dans la salle 2 : attendu : il quitte la salle 1 (film_id null) et passe dans la salle 2
select public.set_screening(2, (select film_id from public.cinema_screens
                                 where user_id = '00000000-0000-0000-0000-000000000000' and screen_no = 1))
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 9b. attendu : ERROR « Ce film n'est pas dans ta collection »
select public.set_screening(1, 999999999)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 9c. attendu : ERROR « Salle inconnue : 9 »
select public.set_screening(9, null)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 10. Outils admin
-- 10a. joueur non admin : attendu : ERROR 42501 « Réservé à l'admin »
select public.admin_add_tickets(500)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

update public.profiles set is_admin = true where id = '00000000-0000-0000-0000-000000000000';

-- 10b. attendu : tickets + 500
select public.admin_add_tickets(500)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 10c. lancer le guichet puis le terminer gratuitement : attendu : levels.box_office = 1, build = null, rate × 1,1 sur les salles
select public.start_build('box_office')
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

select public.admin_finish_build()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- 10d. attendu : 1 salle sans film, tous les niveaux à 0, tickets = 0 ; la collection ne bouge pas
select public.admin_reset_cinema()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 11. Sécurité : choisir le rôle « authenticated » ou « anon » avec le sélecteur en bas à droite → permission denied
-- update public.cinemas set banked = 99999;
-- update public.profiles set tickets = 99999;
-- insert into public.cinema_screens (user_id, screen_no) values ('00000000-0000-0000-0000-000000000000', 5);
-- update public.cinema_levels set cost = 0;
-- select public._cinema_settle('00000000-0000-0000-0000-000000000000', now());
-- select public.get_cinema_state();      -- rôle anon
