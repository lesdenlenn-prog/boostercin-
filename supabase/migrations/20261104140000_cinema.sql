-- =====================================================================
-- MODE CINÉMA (jeu de gestion idle) — tout est calculé et enregistré ici, à l'heure du serveur.
--
-- Revenu (Billets / heure) :
--   Σ salles [ base de la salle × multiplicateur de rareté du film (empty_mult sans film) ] × (1 + bonus % Guichet + équipements)
--   + revenu de l'Arcade
-- Caisse : en attente = banked + rate × heures entre accrue_from et min(maintenant, last_collect_at + cap_hours).
--   À chaque appel, _cinema_settle fait le point : construction échue appliquée (revenu jusqu'à l'échéance au taux d'avant),
--   revenu mis de côté jusqu'à maintenant au taux en vigueur, puis taux recalculé. Un changement de taux (construction,
--   film, rareté, équilibrage retouché) ne fausse donc jamais le montant déjà accumulé.
-- Une seule construction à la fois, terminée d'elle-même à l'échéance, ou tout de suite contre des gemmes.
--
-- ÉQUILIBRAGE : un seul endroit, les tables cinema_levels, cinema_params et cinema_rarity (modifiables dans le tableau
-- de bord sans migration ; lues par le client). Les fonctions _xxx sont internes (execute révoqué pour tous).
-- =====================================================================

-- =====================================================================
-- 1. CONFIGURATION (lecture seule pour les joueurs)
-- =====================================================================

-- Une ligne par niveau de chaque élément. Salles : level = numéro de la salle (la salle 1 est offerte).
create table public.cinema_levels (
  kind             text     not null check (kind in ('screen', 'arcade', 'box_office', 'popcorn', 'vip', 'sound')),
  level            smallint not null check (level >= 1),
  cost             integer  not null check (cost >= 0),                 -- en Billets
  build_minutes    integer  not null check (build_minutes >= 0),
  income           numeric(10,2) not null default 0 check (income >= 0),     -- salle : revenu de base/h ; arcade : revenu/h à ce niveau
  bonus_pct        numeric(6,2)  not null default 0 check (bonus_pct >= 0),  -- guichet / équipements : bonus total à ce niveau (%)
  requires_screens smallint not null default 0 check (requires_screens >= 0),
  primary key (kind, level)
);

create table public.cinema_params (
  key   text primary key check (key in ('cap_hours', 'empty_mult', 'gem_minutes')),
  value numeric not null check (value > 0)
);

create table public.cinema_rarity (
  rarity public.rarity primary key,
  mult   numeric(6,2) not null check (mult > 0)
);

alter table public.cinema_levels enable row level security;
alter table public.cinema_params enable row level security;
alter table public.cinema_rarity enable row level security;

revoke all on table public.cinema_levels, public.cinema_params, public.cinema_rarity from anon, authenticated;
grant select on table public.cinema_levels, public.cinema_params, public.cinema_rarity to authenticated;
grant all on table public.cinema_levels, public.cinema_params, public.cinema_rarity to service_role;

create policy "cinema_levels: lecture" on public.cinema_levels for select to authenticated using (true);
create policy "cinema_params: lecture" on public.cinema_params for select to authenticated using (true);
create policy "cinema_rarity: lecture" on public.cinema_rarity for select to authenticated using (true);

-- ---------- Tableau d'équilibrage (validé en C0)
insert into public.cinema_params (key, value) values
  ('cap_hours',   12),     -- la caisse se remplit pendant 12 h après une récolte, puis la production s'arrête
  ('empty_mult',  0.25),   -- salle sans film
  ('gem_minutes', 10);     -- « Terminer maintenant » : 1 gemme par tranche de 10 min restante entamée (1 minimum)

insert into public.cinema_rarity (rarity, mult) values
  ('common', 1), ('uncommon', 1.25), ('rare', 1.6), ('epic', 2.2), ('legendary', 3.5), ('ultra', 6);

-- Salles : coût ≈ 150 × 1,55^(n−2), base ≈ 20 × 1,12^(n−1) (arrondis)
insert into public.cinema_levels (kind, level, cost, build_minutes, income) values
  ('screen',  1,      0,    0,  20), ('screen',  2,    150,   30,  20), ('screen',  3,    235,   45,  25),
  ('screen',  4,    360,   60,  30), ('screen',  5,    560,   90,  30), ('screen',  6,    865,  120,  35),
  ('screen',  7,   1350,  150,  40), ('screen',  8,   2100,  180,  45), ('screen',  9,   3200,  210,  50),
  ('screen', 10,   5000,  240,  55), ('screen', 11,   7750,  300,  60), ('screen', 12,  12000,  360,  70),
  ('screen', 13,  18500,  420,  80), ('screen', 14,  29000,  480,  85), ('screen', 15,  44500,  600, 100),
  ('screen', 16,  69500,  720, 110), ('screen', 17, 105000,  840, 125), ('screen', 18, 165000,  960, 135),
  ('screen', 19, 260000, 1200, 155), ('screen', 20, 400000, 1440, 170);

-- Arcade : revenu fixe (total à ce niveau), dès 2 salles
insert into public.cinema_levels (kind, level, cost, build_minutes, income, requires_screens) values
  ('arcade',  1,    400,  15,  10, 2), ('arcade',  2,    760,  30,  15, 2), ('arcade',  3,   1450,  60,  20, 2),
  ('arcade',  4,   2750,  90,  30, 2), ('arcade',  5,   5200, 120,  45, 2), ('arcade',  6,   9900, 180,  65, 2),
  ('arcade',  7,  19000, 240,  95, 2), ('arcade',  8,  36000, 360, 135, 2), ('arcade',  9,  68000, 480, 195, 2),
  ('arcade', 10, 130000, 720, 285, 2);

-- Guichet : +10 % par niveau sur les salles (niveau 0 au départ : guichet délabré)
insert into public.cinema_levels (kind, level, cost, build_minutes, bonus_pct) values
  ('box_office',  1,   300,  15,  10), ('box_office',  2,   555,  30,  20), ('box_office',  3,  1050,  60,  30),
  ('box_office',  4,  1900,  90,  40), ('box_office',  5,  3500, 120,  50), ('box_office',  6,  6500, 180,  60),
  ('box_office',  7, 12000, 240,  70), ('box_office',  8, 22000, 360,  80), ('box_office',  9, 41000, 480,  90),
  ('box_office', 10, 76000, 720, 100);

-- Équipements : pop-corn +6 %/niveau (3 salles), sièges VIP +8 % (5 salles), son Dolby +10 % (8 salles)
insert into public.cinema_levels (kind, level, cost, build_minutes, bonus_pct, requires_screens) values
  ('popcorn', 1,    800,  30,  6, 3), ('popcorn', 2,   2100,  90, 12, 3), ('popcorn', 3,   5400, 180, 18, 3),
  ('popcorn', 4,  14000, 360, 24, 3), ('popcorn', 5,  36500, 720, 30, 3),
  ('vip',     1,   1000,  30,  8, 5), ('vip',     2,   2800,  90, 16, 5), ('vip',     3,   7850, 180, 24, 5),
  ('vip',     4,  22000, 360, 32, 5), ('vip',     5,  61500, 720, 40, 5),
  ('sound',   1,   2000,  30, 10, 8), ('sound',   2,   5600,  90, 20, 8), ('sound',   3,  15500, 180, 30, 8),
  ('sound',   4,  44000, 360, 40, 8), ('sound',   5, 125000, 720, 50, 8);

-- =====================================================================
-- 2. DONNÉES DU JOUEUR (lecture de ses lignes ; aucune écriture directe du client)
-- =====================================================================

-- Billets : à côté des bobines et des gemmes (le select par table du profil couvre la nouvelle colonne ; aucun grant d'update)
alter table public.profiles add column tickets integer not null default 0 check (tickets >= 0);

create table public.cinemas (
  user_id          uuid primary key references public.profiles (id) on delete cascade,
  rate             numeric(14,4) not null default 0 check (rate >= 0),    -- Billets / heure en vigueur depuis accrue_from
  banked           numeric(16,4) not null default 0 check (banked >= 0),  -- montant mis de côté, pas encore récolté
  accrue_from      timestamptz not null default now(),
  last_collect_at  timestamptz not null default now(),                    -- la caisse est pleine 12 h après
  build_kind       text check (build_kind in ('screen', 'arcade', 'box_office', 'popcorn', 'vip', 'sound')),
  build_level      smallint,
  build_started_at timestamptz,
  build_ends_at    timestamptz,
  created_at       timestamptz not null default now(),
  check ((build_kind is null) = (build_level is null)
     and (build_kind is null) = (build_started_at is null)
     and (build_kind is null) = (build_ends_at is null))
);

-- Une ligne par salle construite. Un film (de la collection) au plus par salle, et dans une seule salle.
-- Carte retirée de la collection (outil admin) → la salle se retrouve sans film.
create table public.cinema_screens (
  user_id   uuid     not null references public.cinemas (user_id) on delete cascade,
  screen_no smallint not null check (screen_no between 1 and 20),
  film_id   integer,
  built_at  timestamptz not null default now(),
  primary key (user_id, screen_no),
  unique (user_id, film_id),
  foreign key (user_id, film_id) references public.collection (user_id, film_id) on delete set null (film_id)
);

-- Arcade, guichet, équipements : niveau atteint (pas de ligne = niveau 0)
create table public.cinema_upgrades (
  user_id uuid     not null references public.cinemas (user_id) on delete cascade,
  kind    text     not null check (kind in ('arcade', 'box_office', 'popcorn', 'vip', 'sound')),
  level   smallint not null check (level >= 1),
  primary key (user_id, kind)
);

alter table public.cinemas enable row level security;
alter table public.cinema_screens enable row level security;
alter table public.cinema_upgrades enable row level security;

revoke all on table public.cinemas, public.cinema_screens, public.cinema_upgrades from anon, authenticated;
grant select on table public.cinemas, public.cinema_screens, public.cinema_upgrades to authenticated;
grant all on table public.cinemas, public.cinema_screens, public.cinema_upgrades to service_role;

create policy "cinemas: lecture du sien" on public.cinemas for select to authenticated
  using (user_id = (select auth.uid()));
create policy "cinema_screens: lecture des siennes" on public.cinema_screens for select to authenticated
  using (user_id = (select auth.uid()));
create policy "cinema_upgrades: lecture des siens" on public.cinema_upgrades for select to authenticated
  using (user_id = (select auth.uid()));

-- =====================================================================
-- 3. FONCTIONS INTERNES
-- =====================================================================

-- ---------- Valeur d'un paramètre (erreur s'il manque : l'équilibrage doit être complet)
create function public._cinema_param(p_key text)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  v numeric;
begin
  select value into v from public.cinema_params where key = p_key;
  if v is null then raise exception 'Paramètre du cinéma manquant : %', p_key; end if;
  return v;
end;
$$;

-- ---------- Bonus total (%) du guichet et des équipements
create function public._cinema_bonus_pct(p_uid uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(l.bonus_pct), 0)
    from public.cinema_upgrades u
    join public.cinema_levels l on l.kind = u.kind and l.level = u.level
   where u.user_id = p_uid and u.kind in ('box_office', 'popcorn', 'vip', 'sound');
$$;

-- ---------- Revenu actuel en Billets / heure (voir la formule en tête de fichier)
create function public._cinema_rate(p_uid uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select round(
           coalesce((select sum(l.income * coalesce(r.mult, public._cinema_param('empty_mult')))
                       from public.cinema_screens cs
                       join public.cinema_levels l on l.kind = 'screen' and l.level = cs.screen_no
                       left join public.collection c on c.user_id = cs.user_id and c.film_id = cs.film_id
                       left join public.cinema_rarity r on r.rarity = c.rarity
                      where cs.user_id = p_uid), 0)
           * (1 + public._cinema_bonus_pct(p_uid) / 100)
         + coalesce((select l.income
                       from public.cinema_upgrades u
                       join public.cinema_levels l on l.kind = 'arcade' and l.level = u.level
                      where u.user_id = p_uid and u.kind = 'arcade'), 0),
         4);
$$;

-- ---------- Billets produits au taux p_rate entre p_from et p_upto (production arrêtée cap_hours après la récolte)
create function public._cinema_accrued(p_rate numeric, p_from timestamptz, p_upto timestamptz, p_collect timestamptz)
returns numeric
language sql
stable
set search_path = ''
as $$
  select greatest(0, extract(epoch from (least(p_upto, p_collect + make_interval(secs => (public._cinema_param('cap_hours') * 3600)::float8)) - p_from)) / 3600)
         * p_rate;
$$;

-- ---------- Niveau actuel d'un élément (salles : nombre de salles construites)
create function public._cinema_level(p_uid uuid, p_kind text)
returns integer
language sql
stable
set search_path = ''
as $$
  select case when p_kind = 'screen'
              then (select count(*)::integer from public.cinema_screens where user_id = p_uid)
              else coalesce((select level::integer from public.cinema_upgrades where user_id = p_uid and kind = p_kind), 0)
         end;
$$;

-- ---------- Prix en gemmes du temps restant
create function public._cinema_gem_price(p_ends timestamptz, p_now timestamptz)
returns integer
language sql
stable
set search_path = ''
as $$
  select case when p_ends is null or p_ends <= p_now then 0
              else greatest(1, ceil(extract(epoch from (p_ends - p_now)) / (public._cinema_param('gem_minutes') * 60)))::integer
         end;
$$;

-- ---------- Construction terminée : la salle ou le niveau s'ajoute, le chantier est libéré
create function public._cinema_apply_build(p_uid uuid, p_kind text, p_level integer)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  if p_kind = 'screen' then
    insert into public.cinema_screens (user_id, screen_no) values (p_uid, p_level) on conflict do nothing;
  else
    insert into public.cinema_upgrades as u (user_id, kind, level) values (p_uid, p_kind, p_level)
    on conflict (user_id, kind) do update set level = greatest(u.level, excluded.level);
  end if;
  update public.cinemas
     set build_kind = null, build_level = null, build_started_at = null, build_ends_at = null
   where user_id = p_uid;
end;
$$;

-- ---------- Faire le point à l'instant p_now (crée le cinéma la 1re fois : petit hall + salle 1)
-- À appeler profil verrouillé.
create function public._cinema_settle(p_uid uuid, p_now timestamptz)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  cin      public.cinemas%rowtype;
  v_banked numeric;
  v_from   timestamptz;
  v_rate   numeric;
begin
  select * into cin from public.cinemas where user_id = p_uid for update;
  if not found then
    insert into public.cinemas (user_id, accrue_from, last_collect_at, created_at) values (p_uid, p_now, p_now, p_now);
    insert into public.cinema_screens (user_id, screen_no, built_at) values (p_uid, 1, p_now);
    update public.cinemas set rate = public._cinema_rate(p_uid) where user_id = p_uid;
    return;
  end if;

  v_banked := cin.banked;
  v_from := least(cin.accrue_from, p_now);
  v_rate := cin.rate;

  -- 1. construction arrivée à échéance : revenu jusqu'à l'échéance au taux d'avant, puis elle compte
  if cin.build_kind is not null and cin.build_ends_at <= p_now then
    v_banked := v_banked + public._cinema_accrued(v_rate, v_from, cin.build_ends_at, cin.last_collect_at);
    v_from := greatest(v_from, cin.build_ends_at);
    perform public._cinema_apply_build(p_uid, cin.build_kind, cin.build_level);
    v_rate := public._cinema_rate(p_uid);
  end if;

  -- 2. revenu jusqu'à maintenant au taux en vigueur ; 3. nouveau taux (films, raretés ou équilibrage modifiés)
  v_banked := v_banked + public._cinema_accrued(v_rate, v_from, p_now, cin.last_collect_at);
  update public.cinemas
     set banked = v_banked, accrue_from = p_now, rate = public._cinema_rate(p_uid)
   where user_id = p_uid;
end;
$$;

-- ---------- Joueur connecté : verrou sur son profil (ses actions passent l'une après l'autre), puis point à jour
create function public._cinema_begin(p_uid uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
begin
  if p_uid is null then raise exception 'Connexion requise' using errcode = '42501'; end if;
  perform 1 from public.profiles where id = p_uid for update;
  if not found then raise exception 'Profil introuvable'; end if;
  perform public._cinema_settle(p_uid, now());
  return p_uid;
end;
$$;

-- ---------- État complet du cinéma (sans rien écrire ; à appeler après _cinema_settle)
/* {tickets, gems, rate, pending, pending_exact, cap_hours, last_collect_at, full_at, server_now,
    bonus_pct, arcade_income,
    screens: [{no, film_id, title, year, poster, rarity, mult, base, income}],
    levels: {screen, arcade, box_office, popcorn, vip, sound},
    build: null | {kind, level, started_at, ends_at, ms_left, gem_price}}
   La caisse avance côté client : pending_exact + rate × heures écoulées depuis server_now, sans dépasser full_at. */
create function public._cinema_state_json(p_uid uuid, p_now timestamptz)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  cin       public.cinemas%rowtype;
  prof      public.profiles%rowtype;
  v_bonus   numeric := public._cinema_bonus_pct(p_uid);
  v_empty   numeric := public._cinema_param('empty_mult');
  v_cap     numeric := public._cinema_param('cap_hours');
  v_pending numeric;
  v_screens jsonb;
  v_arcade  numeric;
begin
  select * into cin from public.cinemas where user_id = p_uid;
  if not found then raise exception 'Cinéma introuvable'; end if;
  select * into prof from public.profiles where id = p_uid;

  v_pending := cin.banked + public._cinema_accrued(cin.rate, cin.accrue_from, p_now, cin.last_collect_at);

  select coalesce(jsonb_agg(jsonb_build_object(
           'no', cs.screen_no, 'film_id', cs.film_id,
           'title', f.title, 'year', f.year, 'poster', f.poster_path, 'rarity', c.rarity,
           'mult', coalesce(r.mult, v_empty), 'base', l.income,
           'income', round(l.income * coalesce(r.mult, v_empty) * (1 + v_bonus / 100), 2))
         order by cs.screen_no), '[]'::jsonb)
    into v_screens
    from public.cinema_screens cs
    join public.cinema_levels l on l.kind = 'screen' and l.level = cs.screen_no
    left join public.collection c on c.user_id = cs.user_id and c.film_id = cs.film_id
    left join public.films f on f.id = cs.film_id
    left join public.cinema_rarity r on r.rarity = c.rarity
   where cs.user_id = p_uid;

  select coalesce(l.income, 0) into v_arcade
    from public.cinema_upgrades u
    join public.cinema_levels l on l.kind = 'arcade' and l.level = u.level
   where u.user_id = p_uid and u.kind = 'arcade';

  return jsonb_build_object(
    'tickets', prof.tickets,
    'gems', prof.gems,
    'rate', round(cin.rate, 2),
    'pending', floor(v_pending)::bigint,
    'pending_exact', round(v_pending, 4),
    'cap_hours', v_cap,
    'last_collect_at', cin.last_collect_at,
    'full_at', cin.last_collect_at + make_interval(secs => (v_cap * 3600)::float8),
    'server_now', p_now,
    'bonus_pct', v_bonus,
    'arcade_income', coalesce(v_arcade, 0),
    'screens', v_screens,
    'levels', jsonb_build_object(
      'screen',     public._cinema_level(p_uid, 'screen'),
      'arcade',     public._cinema_level(p_uid, 'arcade'),
      'box_office', public._cinema_level(p_uid, 'box_office'),
      'popcorn',    public._cinema_level(p_uid, 'popcorn'),
      'vip',        public._cinema_level(p_uid, 'vip'),
      'sound',      public._cinema_level(p_uid, 'sound')),
    'build', case when cin.build_kind is null then null else jsonb_build_object(
      'kind', cin.build_kind, 'level', cin.build_level,
      'started_at', cin.build_started_at, 'ends_at', cin.build_ends_at,
      'ms_left', greatest(0, floor(extract(epoch from (cin.build_ends_at - p_now)) * 1000))::bigint,
      'gem_price', public._cinema_gem_price(cin.build_ends_at, p_now)) end
  );
end;
$$;

-- ---------- Refus (rien n'est écrit) : {ok:false, reason, message, state}
create function public._cinema_refuse(p_uid uuid, p_reason text, p_message text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('ok', false, 'reason', p_reason, 'message', p_message,
                            'state', public._cinema_state_json(p_uid, now()));
$$;

-- =====================================================================
-- 4. API JOUEUR (anonymes compris)
-- =====================================================================

-- ---------- État (fait le point : une construction échue est appliquée)
create function public.get_cinema_state()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._cinema_begin(auth.uid());
begin
  return public._cinema_state_json(v_uid, now());
end;
$$;

-- ---------- Récolter la caisse : la partie entière passe en Billets, la caisse repart pour 12 h
-- {ok:true, collected, state}
create function public.collect_cash()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := public._cinema_begin(auth.uid());
  v_amount integer;
begin
  select floor(banked)::integer into v_amount from public.cinemas where user_id = v_uid;
  update public.profiles set tickets = tickets + v_amount where id = v_uid;
  update public.cinemas
     set banked = banked - v_amount, last_collect_at = now(), accrue_from = now()
   where user_id = v_uid;
  return jsonb_build_object('ok', true, 'collected', v_amount, 'state', public._cinema_state_json(v_uid, now()));
end;
$$;

-- ---------- Lancer la construction du niveau suivant d'un élément (salle : la suivante)
-- {ok:true, cost, state} | refus : busy, max, locked, insufficient_tickets
create function public.start_build(p_kind text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := public._cinema_begin(auth.uid());
  cin       public.cinemas%rowtype;
  lvl       public.cinema_levels%rowtype;
  v_level   integer;
  v_screens integer;
  v_tickets integer;
begin
  if p_kind is null or p_kind not in ('screen', 'arcade', 'box_office', 'popcorn', 'vip', 'sound') then
    raise exception 'Élément inconnu : %', p_kind using errcode = '22023';
  end if;
  select * into cin from public.cinemas where user_id = v_uid;
  if cin.build_kind is not null then
    return public._cinema_refuse(v_uid, 'busy', 'Une construction est déjà en cours.');
  end if;

  v_level := public._cinema_level(v_uid, p_kind) + 1;
  select * into lvl from public.cinema_levels where kind = p_kind and level = v_level;
  if not found then
    return public._cinema_refuse(v_uid, 'max', 'Niveau maximum atteint.');
  end if;
  v_screens := public._cinema_level(v_uid, 'screen');
  if v_screens < lvl.requires_screens then
    return public._cinema_refuse(v_uid, 'locked', format('Disponible à partir de %s salles.', lvl.requires_screens));
  end if;
  select tickets into v_tickets from public.profiles where id = v_uid;
  if v_tickets < lvl.cost then
    return public._cinema_refuse(v_uid, 'insufficient_tickets', format('Il te manque %s billets.', lvl.cost - v_tickets));
  end if;

  update public.profiles set tickets = tickets - lvl.cost where id = v_uid;
  update public.cinemas
     set build_kind = p_kind, build_level = v_level,
         build_started_at = now(), build_ends_at = now() + lvl.build_minutes * interval '1 minute'
   where user_id = v_uid;
  if lvl.build_minutes = 0 then perform public._cinema_settle(v_uid, now()); end if;   -- immédiat

  return jsonb_build_object('ok', true, 'cost', lvl.cost, 'state', public._cinema_state_json(v_uid, now()));
end;
$$;

-- ---------- « Terminer maintenant » : prix en gemmes du temps restant ; p_max_gems = prix affiché au joueur
-- (refusé si le prix a augmenté ; s'il a baissé entre-temps, on paie le prix actuel)
-- {ok:true, cost_gems, state} | refus : no_build, price_changed, insufficient_gems
create function public.finish_build_with_gems(p_max_gems integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := public._cinema_begin(auth.uid());
  cin     public.cinemas%rowtype;
  v_price integer;
  v_gems  integer;
begin
  select * into cin from public.cinemas where user_id = v_uid;
  if cin.build_kind is null then                          -- ex. terminée d'elle-même juste avant
    return public._cinema_refuse(v_uid, 'no_build', 'Aucune construction en cours.');
  end if;
  v_price := public._cinema_gem_price(cin.build_ends_at, now());
  if p_max_gems is null or v_price > p_max_gems then
    return public._cinema_refuse(v_uid, 'price_changed', format('Le prix est maintenant de %s gemmes.', v_price));
  end if;
  select gems into v_gems from public.profiles where id = v_uid;
  if v_gems < v_price then
    return public._cinema_refuse(v_uid, 'insufficient_gems', format('Il te manque %s gemmes.', v_price - v_gems));
  end if;

  update public.profiles set gems = gems - v_price where id = v_uid;
  update public.cinemas set build_ends_at = now() where user_id = v_uid;
  perform public._cinema_settle(v_uid, now());            -- applique la construction, nouveau taux
  return jsonb_build_object('ok', true, 'cost_gems', v_price, 'state', public._cinema_state_json(v_uid, now()));
end;
$$;

-- ---------- Film projeté dans une salle (null = aucun). Un film déjà projeté ailleurs est déplacé ici.
-- {ok:true, state}
create function public.set_screening(p_screen integer, p_film integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._cinema_begin(auth.uid());       -- revenu mis de côté au taux d'avant le changement
begin
  if not exists (select 1 from public.cinema_screens where user_id = v_uid and screen_no = p_screen) then
    raise exception 'Salle inconnue : %', p_screen using errcode = '22023';
  end if;
  if p_film is not null then
    if not exists (select 1 from public.collection where user_id = v_uid and film_id = p_film) then
      raise exception 'Ce film n''est pas dans ta collection' using errcode = '22023';
    end if;
    update public.cinema_screens set film_id = null
     where user_id = v_uid and film_id = p_film and screen_no <> p_screen;
  end if;
  update public.cinema_screens set film_id = p_film where user_id = v_uid and screen_no = p_screen;
  perform public._cinema_settle(v_uid, now());            -- nouveau taux (aucun temps écoulé depuis le point)
  return jsonb_build_object('ok', true, 'state', public._cinema_state_json(v_uid, now()));
end;
$$;

-- =====================================================================
-- 5. OUTILS ADMIN (vérifient profiles.is_admin via _require_admin ; renvoient l'état du cinéma)
-- =====================================================================

-- ---------- +N Billets
create function public.admin_add_tickets(p_amount integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._cinema_begin(public._require_admin());
begin
  if p_amount is null or p_amount < 1 or p_amount > 10000000 then
    raise exception 'Montant invalide : entre 1 et 10 000 000' using errcode = '22023';
  end if;
  update public.profiles set tickets = tickets + p_amount where id = v_uid;
  return public._cinema_state_json(v_uid, now());
end;
$$;

-- ---------- Terminer la construction en cours, gratuitement
create function public.admin_finish_build()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._cinema_begin(public._require_admin());
begin
  update public.cinemas set build_ends_at = now() where user_id = v_uid and build_kind is not null;
  perform public._cinema_settle(v_uid, now());
  return public._cinema_state_json(v_uid, now());
end;
$$;

-- ---------- Repartir de zéro : cinéma de départ, 0 Billet (bobines, gemmes et collection intactes)
create function public.admin_reset_cinema()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._cinema_begin(public._require_admin());
begin
  delete from public.cinemas where user_id = v_uid;       -- salles et niveaux partent avec (cascade)
  update public.profiles set tickets = 0 where id = v_uid;
  perform public._cinema_settle(v_uid, now());            -- recrée le petit hall et la salle 1
  return public._cinema_state_json(v_uid, now());
end;
$$;

-- =====================================================================
-- 6. DROITS
-- =====================================================================
revoke execute on function public._cinema_param(text) from public, anon, authenticated;
revoke execute on function public._cinema_bonus_pct(uuid) from public, anon, authenticated;
revoke execute on function public._cinema_rate(uuid) from public, anon, authenticated;
revoke execute on function public._cinema_accrued(numeric, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public._cinema_level(uuid, text) from public, anon, authenticated;
revoke execute on function public._cinema_gem_price(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public._cinema_apply_build(uuid, text, integer) from public, anon, authenticated;
revoke execute on function public._cinema_settle(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public._cinema_begin(uuid) from public, anon, authenticated;
revoke execute on function public._cinema_state_json(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public._cinema_refuse(uuid, text, text) from public, anon, authenticated;

revoke execute on function public.get_cinema_state() from public, anon, authenticated;
revoke execute on function public.collect_cash() from public, anon, authenticated;
revoke execute on function public.start_build(text) from public, anon, authenticated;
revoke execute on function public.finish_build_with_gems(integer) from public, anon, authenticated;
revoke execute on function public.set_screening(integer, integer) from public, anon, authenticated;
revoke execute on function public.admin_add_tickets(integer) from public, anon, authenticated;
revoke execute on function public.admin_finish_build() from public, anon, authenticated;
revoke execute on function public.admin_reset_cinema() from public, anon, authenticated;

grant execute on function public.get_cinema_state() to authenticated;
grant execute on function public.collect_cash() to authenticated;
grant execute on function public.start_build(text) to authenticated;
grant execute on function public.finish_build_with_gems(integer) to authenticated;
grant execute on function public.set_screening(integer, integer) to authenticated;
-- ouvertes à authenticated : le contrôle is_admin se fait dans la fonction (un joueur reçoit « Réservé à l'admin »)
grant execute on function public.admin_add_tickets(integer) to authenticated;
grant execute on function public.admin_finish_build() to authenticated;
grant execute on function public.admin_reset_cinema() to authenticated;
