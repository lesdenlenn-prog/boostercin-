-- =====================================================================
-- NETTOYAGE DE L'ANCIEN MODÈLE DU CINÉMA (niveaux : cinemas, cinema_screens, cinema_upgrades, cinema_levels, cinema_params)
-- À appliquer APRÈS la mise en ligne du client « cinéma jouable sur le plan » (fonctions cine_*, migration 20261125120000),
-- qui n'utilise plus aucun de ces objets.
--
-- 1. La caisse de l'ancien cinéma est arrêtée à maintenant et versée en Billets (partie entière), pour que personne ne perde
--    ce qu'il n'avait pas encore récolté.
-- 2. Les 19 fonctions et les 5 tables de l'ancien modèle sont supprimées (leurs policies et droits partent avec).
-- Conservés : public.cinema_rarity (multiplicateurs, utilisés par cine_*) et profiles.tickets (Billets).
-- IRRÉVERSIBLE : les salles, films projetés et niveaux de l'ancien cinéma disparaissent.
-- =====================================================================

do $$
begin
  if to_regclass('public.cine_states') is null or to_regclass('public.cine_rooms') is null then
    raise exception 'Le nouveau modèle (cine_*) est absent : nettoyage annulé';
  end if;
end $$;

-- ---------- 1. Caisse de l'ancien cinéma → Billets
do $$
declare
  r record;
begin
  for r in select user_id from public.cinemas loop
    perform 1 from public.profiles where id = r.user_id for update;
    perform public._cinema_settle(r.user_id, now());       -- revenu mis de côté jusqu'à maintenant (plafond 12 h compris)
  end loop;
  update public.profiles p
     set tickets = p.tickets + floor(c.banked)::integer
    from public.cinemas c
   where c.user_id = p.id and c.banked >= 1;
end $$;

-- ---------- 2. Fonctions de l'ancien modèle
drop function public.get_cinema_state();
drop function public.collect_cash();
drop function public.start_build(text);
drop function public.finish_build_with_gems(integer);
drop function public.set_screening(integer, integer);
drop function public.admin_add_tickets(integer);
drop function public.admin_finish_build();
drop function public.admin_reset_cinema();
drop function public._cinema_refuse(uuid, text, text);
drop function public._cinema_state_json(uuid, timestamptz);
drop function public._cinema_begin(uuid);
drop function public._cinema_settle(uuid, timestamptz);
drop function public._cinema_apply_build(uuid, text, integer);
drop function public._cinema_gem_price(timestamptz, timestamptz);
drop function public._cinema_level(uuid, text);
drop function public._cinema_accrued(numeric, timestamptz, timestamptz, timestamptz);
drop function public._cinema_rate(uuid);
drop function public._cinema_bonus_pct(uuid);
drop function public._cinema_param(text);

-- ---------- 3. Tables de l'ancien modèle (les salles et niveaux d'abord : elles dépendent de cinemas)
drop table public.cinema_screens;
drop table public.cinema_upgrades;
drop table public.cinemas;
drop table public.cinema_levels;
drop table public.cinema_params;
