-- =====================================================================
-- TESTS MANUELS des outils admin — à coller BLOC PAR BLOC dans le SQL Editor.
-- Même préparation que open_booster.sql : joueur de test, UID à remplacer (Ctrl+H), à supprimer à la fin.
-- Ne pas commiter ce fichier avec un vrai UID.
-- =====================================================================


-- ---------- 1. Joueur NON admin : refusé (attendu : ERROR 42501 « Réservé à l'admin »)
select public.admin_add_resource('reels', 100)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 2. Passer le joueur admin (comme pour ton vrai compte plus tard)
update public.profiles set is_admin = true where id = '00000000-0000-0000-0000-000000000000';


-- ---------- 3. +100 bobines puis +100 gemmes (attendu : reels = 100, puis gems = 100)
select public.admin_add_resource('reels', 100)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

select public.admin_add_resource('gems', 100)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

-- attendu : ERROR 22023 « Ressource inconnue »
select public.admin_add_resource('energy', 5)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 4. Mode démo (attendu : demo_mode = true, puis false)
select public.admin_set_demo(true)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

select public.admin_set_demo(false)
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 5. Ouvrir un booster puis vider la collection (attendu : deleted = 5, state.boosters_opened inchangé)
select public.open_booster()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;

select public.admin_reset_collection()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 6. RESET RESSOURCES (attendu : reels = 0, gems = 0, energy.n = 0, ms_to_next ≈ 14 400 000, cost_reels = 60)
select public.admin_reset_resources()
  from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true)) as jwt;


-- ---------- 7. Sécurité : rôle « anon » (sélecteur en bas à droite) → permission denied
-- select public.admin_add_resource('reels', 100);
-- select public._require_admin();      -- permission denied aussi en « authenticated »
