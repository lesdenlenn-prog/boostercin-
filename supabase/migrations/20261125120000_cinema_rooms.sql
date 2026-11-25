-- =====================================================================
-- CINÉMA JOUABLE SUR LE PLAN (étape J1) : pièces posées sur une grille de 40 × 40 cases.
--
-- Nouveau modèle, installé À CÔTÉ de l'ancien (cinemas, cinema_screens, cinema_upgrades, get_cinema_state…) que le
-- site en ligne utilise encore : tables et fonctions préfixées cine_. Seuls profiles.tickets et profiles.gems sont
-- partagés. L'ancien modèle sera supprimé par une migration de nettoyage au moment de la fusion dans main.
--
-- Pièces : base identique pour tous (couloir d'accueil `hall` + `box_office`, au milieu bas de la grille), puis
--   projection, arcade, toilets, snacks, corridor en 3 tailles (S, M, L), posées sur des cases libres, collées au bâtiment.
--   Vue trois quarts : une pièce fait au moins 4 × 4 cases ; une porte se crée sur le mur commun avec une pièce existante :
--     mur vertical (est/ouest)  : rangées [y + 2, y + h − 1) des DEUX pièces, longueur 1 à 3 cases ;
--     mur horizontal (nord/sud) : colonnes [x + 1, x + w − 1) des deux pièces, longueur 2 cases (il en faut au moins 2).
--   La porte est enregistrée des deux côtés : doors = [{side, at, len, to}] (at compté depuis le coin haut-gauche).
-- Prix : cases × prix par case du type × price_growth ^ (pièces de ce type déjà possédées) ; 1re salle de projection
--   offerte et immédiate (first_screen_free). Une seule construction à la fois (pièce ou niveau du guichet).
-- Revenu (Billets / heure) :
--   [ Σ projection : revenu de la taille × rareté du film (empty_mult sans film) + Σ machines × machine_income ]
--   × (1 + bonus % : guichet + toilettes + boutiques)
-- Arcade : livrée avec 1 machine ; machines achetées ensuite (prix croissant), 1 case chacune, posées sur le sol de la
--   salle : colonnes [1, w − 1), rangées [2, h − 1) (coordonnées relatives à la salle).
-- Caisse, plafond 12 h, prix en gemmes : mêmes règles que l'ancien modèle.
-- ÉQUILIBRAGE : cine_params, cine_room_types, cine_box_office (+ cinema_rarity, partagée), modifiables sans migration.
-- =====================================================================

-- =====================================================================
-- 1. CONFIGURATION (lecture seule pour les joueurs)
-- =====================================================================
create table public.cine_params (
  key   text primary key,
  value numeric not null check (value >= 0)
);

create table public.cine_room_types (
  type          text     not null check (type in ('projection', 'arcade', 'toilets', 'snacks', 'corridor')),
  size          text     not null check (size in ('S', 'M', 'L')),
  w             smallint not null check (w >= 4),
  h             smallint not null check (h >= 4),
  cost_per_cell integer  not null check (cost_per_cell >= 0),       -- en Billets
  build_minutes integer  not null check (build_minutes >= 0),
  income        numeric(10,2) not null default 0 check (income >= 0),    -- projection : revenu de base / h
  bonus_pct     numeric(6,2)  not null default 0 check (bonus_pct >= 0), -- toilettes, boutiques : bonus pour tout le cinéma
  primary key (type, size)
);

create table public.cine_box_office (
  level         smallint primary key check (level >= 1),
  cost          integer  not null check (cost >= 0),
  build_minutes integer  not null check (build_minutes >= 0),
  bonus_pct     numeric(6,2) not null check (bonus_pct >= 0)          -- bonus total à ce niveau
);

alter table public.cine_params enable row level security;
alter table public.cine_room_types enable row level security;
alter table public.cine_box_office enable row level security;
revoke all on table public.cine_params, public.cine_room_types, public.cine_box_office from anon, authenticated;
grant select on table public.cine_params, public.cine_room_types, public.cine_box_office to authenticated;
grant all on table public.cine_params, public.cine_room_types, public.cine_box_office to service_role;
create policy "cine_params: lecture" on public.cine_params for select to authenticated using (true);
create policy "cine_room_types: lecture" on public.cine_room_types for select to authenticated using (true);
create policy "cine_box_office: lecture" on public.cine_box_office for select to authenticated using (true);

insert into public.cine_params (key, value) values
  ('grid_cols', 40), ('grid_rows', 40),
  ('cap_hours', 12),          -- la caisse se remplit pendant 12 h après une récolte
  ('empty_mult', 0.25),       -- salle de projection sans film
  ('gem_minutes', 10),        -- finir tout de suite : 1 gemme par tranche de 10 min restante entamée (1 minimum)
  ('price_growth', 1.5),      -- chaque pièce du même type coûte × 1,5
  ('first_screen_free', 1),   -- 1 = la 1re salle de projection est offerte et immédiate
  ('machine_cost', 100), ('machine_growth', 1.5), ('machine_income', 10);

insert into public.cine_room_types (type, size, w, h, cost_per_cell, build_minutes, income, bonus_pct) values
  ('projection', 'S', 4, 5, 20,  15, 20,  0), ('projection', 'M', 5, 6, 20,  45, 35,  0), ('projection', 'L', 6, 8, 20, 120, 60,  0),
  ('arcade',     'S', 4, 5, 20,  15,  0,  0), ('arcade',     'M', 5, 6, 20,  45,  0,  0), ('arcade',     'L', 6, 7, 20, 120,  0,  0),
  ('toilets',    'S', 4, 4, 10,  15,  0,  5), ('toilets',    'M', 4, 5, 10,  45,  0, 10), ('toilets',    'L', 5, 5, 10, 120,  0, 15),
  ('snacks',     'S', 4, 4, 15,  15,  0,  8), ('snacks',     'M', 4, 5, 15,  45,  0, 15), ('snacks',     'L', 5, 5, 15, 120,  0, 25),
  ('corridor',   'S', 4, 4,  5,   5,  0,  0), ('corridor',   'M', 4, 6,  5,  10,  0,  0), ('corridor',   'L', 4, 8,  5,  20,  0,  0);

-- Guichet : mêmes niveaux que l'ancien modèle (+10 % par niveau ; niveau 0 au départ)
insert into public.cine_box_office (level, cost, build_minutes, bonus_pct) values
  (1, 300, 15, 10), (2, 555, 30, 20), (3, 1050, 60, 30), (4, 1900, 90, 40), (5, 3500, 120, 50),
  (6, 6500, 180, 60), (7, 12000, 240, 70), (8, 22000, 360, 80), (9, 41000, 480, 90), (10, 76000, 720, 100);

-- =====================================================================
-- 2. DONNÉES DU JOUEUR (lecture de ses lignes ; aucune écriture directe du client)
-- =====================================================================
create table public.cine_states (
  user_id          uuid primary key references public.profiles (id) on delete cascade,
  rate             numeric(14,4) not null default 0 check (rate >= 0),
  banked           numeric(16,4) not null default 0 check (banked >= 0),
  accrue_from      timestamptz not null default now(),
  last_collect_at  timestamptz not null default now(),
  box_office_level smallint not null default 0 check (box_office_level >= 0),
  build_room_id    bigint,                    -- pièce en chantier
  build_box_office smallint,                  -- ou niveau du guichet en cours
  build_started_at timestamptz,
  build_ends_at    timestamptz,
  created_at       timestamptz not null default now(),
  check (num_nonnulls(build_room_id, build_box_office) <= 1),
  check ((build_started_at is null) = (build_ends_at is null)
     and (build_started_at is null) = (build_room_id is null and build_box_office is null))
);

create table public.cine_rooms (
  id         bigint generated always as identity primary key,
  user_id    uuid     not null references public.cine_states (user_id) on delete cascade,
  type       text     not null check (type in ('hall', 'box_office', 'projection', 'arcade', 'toilets', 'snacks', 'corridor')),
  size       text     check (size in ('S', 'M', 'L')),          -- null pour la base
  x          smallint not null check (x >= 0),
  y          smallint not null check (y >= 0),
  w          smallint not null check (w >= 1),
  h          smallint not null check (h >= 1),
  doors      jsonb    not null default '[]'::jsonb,
  film_id    integer,
  built_at   timestamptz,                                       -- null = en chantier
  created_at timestamptz not null default now(),
  check (film_id is null or type = 'projection'),
  unique (user_id, film_id),
  foreign key (user_id, film_id) references public.collection (user_id, film_id) on delete set null (film_id)
);
create index cine_rooms_user on public.cine_rooms (user_id);

create table public.cine_machines (
  id        bigint generated always as identity primary key,
  user_id   uuid     not null references public.cine_states (user_id) on delete cascade,
  room_id   bigint   not null references public.cine_rooms (id) on delete cascade,
  x         smallint not null,                                  -- case relative à la salle
  y         smallint not null,
  bought_at timestamptz not null default now(),
  unique (room_id, x, y)
);
create index cine_machines_user on public.cine_machines (user_id);

alter table public.cine_states enable row level security;
alter table public.cine_rooms enable row level security;
alter table public.cine_machines enable row level security;
revoke all on table public.cine_states, public.cine_rooms, public.cine_machines from anon, authenticated;
grant select on table public.cine_states, public.cine_rooms, public.cine_machines to authenticated;
grant all on table public.cine_states, public.cine_rooms, public.cine_machines to service_role;
create policy "cine_states: lecture du sien" on public.cine_states for select to authenticated
  using (user_id = (select auth.uid()));
create policy "cine_rooms: lecture des siennes" on public.cine_rooms for select to authenticated
  using (user_id = (select auth.uid()));
create policy "cine_machines: lecture des siennes" on public.cine_machines for select to authenticated
  using (user_id = (select auth.uid()));

-- =====================================================================
-- 3. FONCTIONS INTERNES
-- =====================================================================

-- ---------- Paramètre (erreur s'il manque)
create function public._cine_param(p_key text)
returns numeric language plpgsql stable set search_path = '' as $$
declare v numeric;
begin
  select value into v from public.cine_params where key = p_key;
  if v is null then raise exception 'Paramètre du cinéma manquant : %', p_key; end if;
  return v;
end;
$$;

-- ---------- Bonus total (%) : guichet + toilettes et boutiques construites
create function public._cine_bonus_pct(p_uid uuid)
returns numeric language sql stable set search_path = '' as $$
  select coalesce((select b.bonus_pct from public.cine_states s join public.cine_box_office b on b.level = s.box_office_level
                    where s.user_id = p_uid), 0)
       + coalesce((select sum(t.bonus_pct) from public.cine_rooms r
                     join public.cine_room_types t on t.type = r.type and t.size = r.size
                    where r.user_id = p_uid and r.built_at is not null), 0);
$$;

-- ---------- Revenu de base d'une salle de projection (avant bonus)
create function public._cine_screen_income(p_uid uuid, p_room bigint)
returns numeric language sql stable set search_path = '' as $$
  select t.income * coalesce(ra.mult, public._cine_param('empty_mult'))
    from public.cine_rooms r
    join public.cine_room_types t on t.type = r.type and t.size = r.size
    left join public.collection c on c.user_id = r.user_id and c.film_id = r.film_id
    left join public.cinema_rarity ra on ra.rarity = c.rarity
   where r.id = p_room and r.user_id = p_uid;
$$;

-- ---------- Revenu actuel en Billets / heure
create function public._cine_rate(p_uid uuid)
returns numeric language sql stable set search_path = '' as $$
  select round(
           ( coalesce((select sum(public._cine_screen_income(p_uid, r.id)) from public.cine_rooms r
                        where r.user_id = p_uid and r.type = 'projection' and r.built_at is not null), 0)
           + (select count(*) from public.cine_machines m join public.cine_rooms r on r.id = m.room_id
               where m.user_id = p_uid and r.built_at is not null) * public._cine_param('machine_income') )
           * (1 + public._cine_bonus_pct(p_uid) / 100), 4);
$$;

-- ---------- Billets produits au taux p_rate entre p_from et p_upto (arrêt cap_hours après la récolte)
create function public._cine_accrued(p_rate numeric, p_from timestamptz, p_upto timestamptz, p_collect timestamptz)
returns numeric language sql stable set search_path = '' as $$
  select greatest(0, extract(epoch from (least(p_upto, p_collect + make_interval(secs => (public._cine_param('cap_hours') * 3600)::float8)) - p_from)) / 3600)
         * p_rate;
$$;

-- ---------- Prix en gemmes du temps restant
create function public._cine_gem_price(p_ends timestamptz, p_now timestamptz)
returns integer language sql stable set search_path = '' as $$
  select case when p_ends is null or p_ends <= p_now then 0
              else greatest(1, ceil(extract(epoch from (p_ends - p_now)) / (public._cine_param('gem_minutes') * 60)))::integer
         end;
$$;

-- ---------- Prix (Billets) et durée d'une nouvelle pièce : {cost, minutes} ; 1re salle de projection offerte
create function public._cine_room_offer(p_uid uuid, p_type text, p_size text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  t public.cine_room_types%rowtype;
  n integer;
begin
  select * into t from public.cine_room_types where type = p_type and size = p_size;
  if not found then return null; end if;
  select count(*) into n from public.cine_rooms where user_id = p_uid and type = p_type;
  if p_type = 'projection' and n = 0 and public._cine_param('first_screen_free') > 0 then
    return jsonb_build_object('cost', 0, 'minutes', 0);
  end if;
  return jsonb_build_object(
    'cost', round(t.w * t.h * t.cost_per_cell * power(public._cine_param('price_growth'), n))::integer,
    'minutes', t.build_minutes);
end;
$$;

-- ---------- Prix de la prochaine machine d'arcade (les machines offertes avec chaque salle ne comptent pas)
create function public._cine_machine_price(p_uid uuid)
returns integer language sql stable set search_path = '' as $$
  select round(public._cine_param('machine_cost')
               * power(public._cine_param('machine_growth'),
                       greatest(0, (select count(*) from public.cine_machines where user_id = p_uid)
                                 - (select count(*) from public.cine_rooms where user_id = p_uid and type = 'arcade' and built_at is not null))))::integer;
$$;

-- ---------- Porte possible entre une nouvelle pièce N et une pièce existante O (rectangles en cases) ; null sinon.
-- {side, at, side_o, at_o, len, span} : side/at pour N, side_o/at_o pour O, span = longueur utilisable du mur commun.
create function public._cine_door(nx int, ny int, nw int, nh int, ox int, oy int, ow int, oh int)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  lo int; hi int; l int; len int; st int; s text; so text;
begin
  if nx + nw = ox or ox + ow = nx then                         -- mur vertical commun
    s  := case when nx + nw = ox then 'e' else 'w' end;
    so := case when s = 'e' then 'w' else 'e' end;
    lo := greatest(ny, oy) + 2;
    hi := least(ny + nh, oy + oh) - 1;
    l  := hi - lo;
    if l < 1 then return null; end if;
    len := least(3, l);
    st := lo + (l - len) / 2;
    return jsonb_build_object('side', s, 'at', st - ny, 'side_o', so, 'at_o', st - oy, 'len', len, 'span', l);
  elsif ny + nh = oy or oy + oh = ny then                      -- mur horizontal commun
    s  := case when ny + nh = oy then 's' else 'n' end;
    so := case when s = 's' then 'n' else 's' end;
    lo := greatest(nx, ox) + 1;
    hi := least(nx + nw, ox + ow) - 1;
    l  := hi - lo;
    if l < 2 then return null; end if;
    len := 2;
    st := lo + (l - len) / 2;
    return jsonb_build_object('side', s, 'at', st - nx, 'side_o', so, 'at_o', st - ox, 'len', len, 'span', l);
  end if;
  return null;
end;
$$;

-- ---------- Une case de machine est-elle sur le sol de la salle ? (coordonnées relatives)
create function public._cine_floor_cell(p_w int, p_h int, p_x int, p_y int)
returns boolean language sql immutable set search_path = '' as $$
  select p_x >= 1 and p_x < p_w - 1 and p_y >= 2 and p_y < p_h - 1;
$$;

-- ---------- Construction terminée (à l'échéance) : pièce ouverte (arcade : 1 machine offerte) ou niveau du guichet
create function public._cine_apply_build(p_uid uuid, p_at timestamptz)
returns void language plpgsql volatile set search_path = '' as $$
declare
  s public.cine_states%rowtype;
  r public.cine_rooms%rowtype;
begin
  select * into s from public.cine_states where user_id = p_uid;
  if s.build_room_id is not null then
    update public.cine_rooms set built_at = p_at where id = s.build_room_id and user_id = p_uid returning * into r;
    if r.type = 'arcade' then
      insert into public.cine_machines (user_id, room_id, x, y, bought_at) values (p_uid, r.id, 1, 2, p_at)
      on conflict do nothing;
    end if;
  elsif s.build_box_office is not null then
    update public.cine_states set box_office_level = greatest(box_office_level, s.build_box_office) where user_id = p_uid;
  end if;
  update public.cine_states
     set build_room_id = null, build_box_office = null, build_started_at = null, build_ends_at = null
   where user_id = p_uid;
end;
$$;

-- ---------- Faire le point à l'instant p_now (crée la base la 1re fois). À appeler profil verrouillé.
create function public._cine_settle(p_uid uuid, p_now timestamptz)
returns void language plpgsql volatile set search_path = '' as $$
declare
  s        public.cine_states%rowtype;
  v_banked numeric;
  v_from   timestamptz;
  v_rate   numeric;
  v_hall   bigint;
  v_box    bigint;
begin
  select * into s from public.cine_states where user_id = p_uid for update;
  if not found then
    -- base identique pour tous : couloir d'accueil (entrée au sud, sur le bord de la grille, to = null) + guichet à l'est
    insert into public.cine_states (user_id, accrue_from, last_collect_at, created_at) values (p_uid, p_now, p_now, p_now);
    insert into public.cine_rooms (user_id, type, x, y, w, h, built_at, created_at)
    values (p_uid, 'hall', 13, 30, 6, 10, p_now, p_now) returning id into v_hall;
    insert into public.cine_rooms (user_id, type, x, y, w, h, built_at, created_at)
    values (p_uid, 'box_office', 19, 32, 8, 7, p_now, p_now) returning id into v_box;
    update public.cine_rooms set doors = jsonb_build_array(jsonb_build_object('side', 's', 'at', 2, 'len', 2, 'to', null),
                                                           jsonb_build_object('side', 'e', 'at', 5, 'len', 3, 'to', v_box))
     where id = v_hall;
    update public.cine_rooms set doors = jsonb_build_array(jsonb_build_object('side', 'w', 'at', 3, 'len', 3, 'to', v_hall))
     where id = v_box;
    return;
  end if;

  v_banked := s.banked;
  v_from := least(s.accrue_from, p_now);
  v_rate := s.rate;

  -- 1. chantier échu : revenu jusqu'à l'échéance au taux d'avant, puis la pièce ou le niveau compte
  if s.build_ends_at is not null and s.build_ends_at <= p_now then
    v_banked := v_banked + public._cine_accrued(v_rate, v_from, s.build_ends_at, s.last_collect_at);
    v_from := greatest(v_from, s.build_ends_at);
    perform public._cine_apply_build(p_uid, s.build_ends_at);
    v_rate := public._cine_rate(p_uid);
  end if;

  -- 2. revenu jusqu'à maintenant au taux en vigueur ; 3. nouveau taux
  v_banked := v_banked + public._cine_accrued(v_rate, v_from, p_now, s.last_collect_at);
  update public.cine_states set banked = v_banked, accrue_from = p_now, rate = public._cine_rate(p_uid)
   where user_id = p_uid;
end;
$$;

-- ---------- Joueur connecté : verrou sur son profil, puis point à jour
create function public._cine_begin(p_uid uuid)
returns uuid language plpgsql volatile set search_path = '' as $$
begin
  if p_uid is null then raise exception 'Connexion requise' using errcode = '42501'; end if;
  perform 1 from public.profiles where id = p_uid for update;
  if not found then raise exception 'Profil introuvable'; end if;
  perform public._cine_settle(p_uid, now());
  return p_uid;
end;
$$;

-- ---------- État complet (sans rien écrire ; à appeler après _cine_settle)
/* {tickets, gems, rate, pending, pending_exact, cap_hours, last_collect_at, full_at, server_now, bonus_pct,
    grid: {cols, rows},
    rooms: [{id, type, size, x, y, w, h, doors, built, film: null | {id, title, year, poster, rarity, mult},
             income (Billets/h, bonus compris), bonus_pct, machines: [{id, x, y}]}],
    offers: [{type, size, w, h, cost, minutes, income, bonus_pct}],     prix du moment de chaque nouvelle pièce
    machine_price, machine_income,
    box_office: {level, bonus_pct, next: null | {level, cost, minutes, bonus_pct}},
    build: null | {kind: 'room' | 'box_office', room_id, level, started_at, ends_at, ms_left, gem_price}} */
create function public._cine_state_json(p_uid uuid, p_now timestamptz)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  s       public.cine_states%rowtype;
  prof    public.profiles%rowtype;
  v_bonus numeric := public._cine_bonus_pct(p_uid);
  v_cap   numeric := public._cine_param('cap_hours');
  v_mi    numeric := public._cine_param('machine_income');
  v_pend  numeric;
  v_rooms jsonb;
  v_offer jsonb;
  v_next  jsonb;
begin
  select * into s from public.cine_states where user_id = p_uid;
  if not found then raise exception 'Cinéma introuvable'; end if;
  select * into prof from public.profiles where id = p_uid;
  v_pend := s.banked + public._cine_accrued(s.rate, s.accrue_from, p_now, s.last_collect_at);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'type', r.type, 'size', r.size, 'x', r.x, 'y', r.y, 'w', r.w, 'h', r.h,
           'doors', r.doors, 'built', r.built_at is not null,
           'film', case when r.film_id is null then null else jsonb_build_object(
                     'id', r.film_id, 'title', f.title, 'year', f.year, 'poster', f.poster_path, 'rarity', c.rarity,
                     'mult', ra.mult) end,
           'income', case when r.built_at is null then 0
                          when r.type = 'projection' then round(public._cine_screen_income(p_uid, r.id) * (1 + v_bonus / 100), 2)
                          when r.type = 'arcade' then round((select count(*) from public.cine_machines m where m.room_id = r.id)
                                                             * v_mi * (1 + v_bonus / 100), 2)
                          else 0 end,
           'bonus_pct', coalesce(t.bonus_pct, 0),
           'machines', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'x', m.x, 'y', m.y) order by m.id)
                                   from public.cine_machines m where m.room_id = r.id), '[]'::jsonb))
         order by r.id), '[]'::jsonb)
    into v_rooms
    from public.cine_rooms r
    left join public.cine_room_types t on t.type = r.type and t.size = r.size
    left join public.collection c on c.user_id = r.user_id and c.film_id = r.film_id
    left join public.films f on f.id = r.film_id
    left join public.cinema_rarity ra on ra.rarity = c.rarity
   where r.user_id = p_uid;

  select coalesce(jsonb_agg(jsonb_build_object('type', t.type, 'size', t.size, 'w', t.w, 'h', t.h,
                    'cost', (o.v->>'cost')::int, 'minutes', (o.v->>'minutes')::int, 'income', t.income, 'bonus_pct', t.bonus_pct)
                  order by array_position(array['projection','arcade','toilets','snacks','corridor'], t.type), t.size desc), '[]'::jsonb)
    into v_offer
    from public.cine_room_types t
    cross join lateral (select public._cine_room_offer(p_uid, t.type, t.size) as v) o;

  select jsonb_build_object('level', b.level, 'cost', b.cost, 'minutes', b.build_minutes, 'bonus_pct', b.bonus_pct)
    into v_next from public.cine_box_office b where b.level = s.box_office_level + 1;

  return jsonb_build_object(
    'tickets', prof.tickets, 'gems', prof.gems,
    'rate', round(s.rate, 2), 'pending', floor(v_pend)::bigint, 'pending_exact', round(v_pend, 4),
    'cap_hours', v_cap, 'last_collect_at', s.last_collect_at,
    'full_at', s.last_collect_at + make_interval(secs => (v_cap * 3600)::float8),
    'server_now', p_now, 'bonus_pct', v_bonus,
    'grid', jsonb_build_object('cols', public._cine_param('grid_cols'), 'rows', public._cine_param('grid_rows')),
    'rooms', v_rooms, 'offers', v_offer,
    'machine_price', public._cine_machine_price(p_uid), 'machine_income', v_mi,
    'box_office', jsonb_build_object('level', s.box_office_level,
                    'bonus_pct', coalesce((select bonus_pct from public.cine_box_office where level = s.box_office_level), 0),
                    'next', v_next),
    'build', case when s.build_ends_at is null then null else jsonb_build_object(
      'kind', case when s.build_room_id is not null then 'room' else 'box_office' end,
      'room_id', s.build_room_id, 'level', s.build_box_office,
      'started_at', s.build_started_at, 'ends_at', s.build_ends_at,
      'ms_left', greatest(0, floor(extract(epoch from (s.build_ends_at - p_now)) * 1000))::bigint,
      'gem_price', public._cine_gem_price(s.build_ends_at, p_now)) end);
end;
$$;

-- ---------- Refus (rien n'est écrit) : {ok:false, reason, message, state}
create function public._cine_refuse(p_uid uuid, p_reason text, p_message text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('ok', false, 'reason', p_reason, 'message', p_message, 'state', public._cine_state_json(p_uid, now()));
$$;

-- =====================================================================
-- 4. API JOUEUR
-- =====================================================================

-- ---------- État
create function public.cine_get_state()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := public._cine_begin(auth.uid());
begin
  return public._cine_state_json(v_uid, now());
end;
$$;

-- ---------- Récolter la caisse : {ok:true, collected, state}
create function public.cine_collect()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid    uuid := public._cine_begin(auth.uid());
  v_amount integer;
begin
  select floor(banked)::integer into v_amount from public.cine_states where user_id = v_uid;
  update public.profiles set tickets = tickets + v_amount where id = v_uid;
  update public.cine_states set banked = banked - v_amount, last_collect_at = now(), accrue_from = now() where user_id = v_uid;
  return jsonb_build_object('ok', true, 'collected', v_amount, 'state', public._cine_state_json(v_uid, now()));
end;
$$;

-- ---------- Construire une pièce : coin haut-gauche (p_x, p_y), p_rotated échange largeur et hauteur.
-- {ok:true, room_id, cost, state} | refus : busy, out_of_grid, overlap, no_door, insufficient_tickets
create function public.cine_build_room(p_type text, p_size text, p_x integer, p_y integer, p_rotated boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid   uuid := public._cine_begin(auth.uid());
  s       public.cine_states%rowtype;
  t       public.cine_room_types%rowtype;
  o       record;
  v_w     int; v_h int;
  v_door  jsonb; v_best jsonb; v_best_id bigint; v_best_rank int; v_rank int;
  v_offer jsonb; v_cost int; v_min int;
  v_tick  int;
  v_id    bigint;
begin
  select * into t from public.cine_room_types where type = p_type and size = p_size;
  if not found then raise exception 'Pièce inconnue : % %', p_type, p_size using errcode = '22023'; end if;
  if p_x is null or p_y is null then raise exception 'Position manquante' using errcode = '22023'; end if;
  select * into s from public.cine_states where user_id = v_uid;
  if s.build_ends_at is not null then
    return public._cine_refuse(v_uid, 'busy', 'Une construction est déjà en cours.');
  end if;

  v_w := case when coalesce(p_rotated, false) then t.h else t.w end;
  v_h := case when coalesce(p_rotated, false) then t.w else t.h end;
  if p_x < 0 or p_y < 0 or p_x + v_w > public._cine_param('grid_cols') or p_y + v_h > public._cine_param('grid_rows') then
    return public._cine_refuse(v_uid, 'out_of_grid', 'La pièce sort du terrain.');
  end if;
  if exists (select 1 from public.cine_rooms r where r.user_id = v_uid
               and p_x < r.x + r.w and r.x < p_x + v_w and p_y < r.y + r.h and r.y < p_y + v_h) then
    return public._cine_refuse(v_uid, 'overlap', 'La place est déjà prise.');
  end if;

  -- porte : mur commun le plus long ; à égalité, couloirs et hall d'abord, puis la pièce la plus ancienne
  for o in select * from public.cine_rooms r where r.user_id = v_uid and r.built_at is not null order by r.id loop
    v_door := public._cine_door(p_x, p_y, v_w, v_h, o.x, o.y, o.w, o.h);
    continue when v_door is null;
    v_rank := (v_door->>'span')::int * 10 + case when o.type in ('corridor', 'hall') then 1 else 0 end;
    if v_best is null or v_rank > v_best_rank then
      v_best := v_door; v_best_id := o.id; v_best_rank := v_rank;
    end if;
  end loop;
  if v_best is null then
    return public._cine_refuse(v_uid, 'no_door', 'La pièce doit toucher le bâtiment par un mur assez long pour une porte.');
  end if;

  v_offer := public._cine_room_offer(v_uid, p_type, p_size);
  v_cost := (v_offer->>'cost')::int;
  v_min  := (v_offer->>'minutes')::int;
  select tickets into v_tick from public.profiles where id = v_uid;
  if v_tick < v_cost then
    return public._cine_refuse(v_uid, 'insufficient_tickets', format('Il te manque %s billets.', v_cost - v_tick));
  end if;

  update public.profiles set tickets = tickets - v_cost where id = v_uid;
  insert into public.cine_rooms (user_id, type, size, x, y, w, h, doors)
  values (v_uid, p_type, p_size, p_x, p_y, v_w, v_h,
          jsonb_build_array(jsonb_build_object('side', v_best->>'side', 'at', (v_best->>'at')::int,
                                               'len', (v_best->>'len')::int, 'to', v_best_id)))
  returning id into v_id;
  update public.cine_rooms
     set doors = doors || jsonb_build_array(jsonb_build_object('side', v_best->>'side_o', 'at', (v_best->>'at_o')::int,
                                                               'len', (v_best->>'len')::int, 'to', v_id))
   where id = v_best_id;
  update public.cine_states
     set build_room_id = v_id, build_started_at = now(), build_ends_at = now() + v_min * interval '1 minute'
   where user_id = v_uid;
  if v_min = 0 then perform public._cine_settle(v_uid, now()); end if;    -- immédiat

  return jsonb_build_object('ok', true, 'room_id', v_id, 'cost', v_cost, 'state', public._cine_state_json(v_uid, now()));
end;
$$;

-- ---------- Améliorer le guichet : {ok:true, cost, state} | refus : busy, max, insufficient_tickets
create function public.cine_upgrade_box_office()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := public._cine_begin(auth.uid());
  s      public.cine_states%rowtype;
  b      public.cine_box_office%rowtype;
  v_tick int;
begin
  select * into s from public.cine_states where user_id = v_uid;
  if s.build_ends_at is not null then return public._cine_refuse(v_uid, 'busy', 'Une construction est déjà en cours.'); end if;
  select * into b from public.cine_box_office where level = s.box_office_level + 1;
  if not found then return public._cine_refuse(v_uid, 'max', 'Niveau maximum atteint.'); end if;
  select tickets into v_tick from public.profiles where id = v_uid;
  if v_tick < b.cost then
    return public._cine_refuse(v_uid, 'insufficient_tickets', format('Il te manque %s billets.', b.cost - v_tick));
  end if;
  update public.profiles set tickets = tickets - b.cost where id = v_uid;
  update public.cine_states
     set build_box_office = b.level, build_started_at = now(), build_ends_at = now() + b.build_minutes * interval '1 minute'
   where user_id = v_uid;
  if b.build_minutes = 0 then perform public._cine_settle(v_uid, now()); end if;
  return jsonb_build_object('ok', true, 'cost', b.cost, 'state', public._cine_state_json(v_uid, now()));
end;
$$;

-- ---------- Finir tout de suite en gemmes ; p_max_gems = prix affiché (refusé s'il a augmenté)
-- {ok:true, cost_gems, state} | refus : no_build, price_changed, insufficient_gems
create function public.cine_finish_with_gems(p_max_gems integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid   uuid := public._cine_begin(auth.uid());
  s       public.cine_states%rowtype;
  v_price int;
  v_gems  int;
begin
  select * into s from public.cine_states where user_id = v_uid;
  if s.build_ends_at is null then return public._cine_refuse(v_uid, 'no_build', 'Aucune construction en cours.'); end if;
  v_price := public._cine_gem_price(s.build_ends_at, now());
  if p_max_gems is null or v_price > p_max_gems then
    return public._cine_refuse(v_uid, 'price_changed', format('Le prix est maintenant de %s gemmes.', v_price));
  end if;
  select gems into v_gems from public.profiles where id = v_uid;
  if v_gems < v_price then
    return public._cine_refuse(v_uid, 'insufficient_gems', format('Il te manque %s gemmes.', v_price - v_gems));
  end if;
  update public.profiles set gems = gems - v_price where id = v_uid;
  update public.cine_states set build_ends_at = now() where user_id = v_uid;
  perform public._cine_settle(v_uid, now());
  return jsonb_build_object('ok', true, 'cost_gems', v_price, 'state', public._cine_state_json(v_uid, now()));
end;
$$;

-- ---------- Film projeté dans une salle (null = aucun). Un film déjà projeté ailleurs est déplacé ici. {ok:true, state}
create function public.cine_set_film(p_room bigint, p_film integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := public._cine_begin(auth.uid());
begin
  if not exists (select 1 from public.cine_rooms where id = p_room and user_id = v_uid and type = 'projection' and built_at is not null) then
    raise exception 'Salle de projection inconnue : %', p_room using errcode = '22023';
  end if;
  if p_film is not null then
    if not exists (select 1 from public.collection where user_id = v_uid and film_id = p_film) then
      raise exception 'Ce film n''est pas dans ta collection' using errcode = '22023';
    end if;
    update public.cine_rooms set film_id = null where user_id = v_uid and film_id = p_film and id <> p_room;
  end if;
  update public.cine_rooms set film_id = p_film where id = p_room;
  perform public._cine_settle(v_uid, now());
  return jsonb_build_object('ok', true, 'state', public._cine_state_json(v_uid, now()));
end;
$$;

-- ---------- Acheter une machine d'arcade sur une case libre du sol de la salle (coordonnées relatives)
-- {ok:true, machine_id, cost, state} | refus : bad_cell, cell_taken, insufficient_tickets
create function public.cine_buy_machine(p_room bigint, p_x integer, p_y integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := public._cine_begin(auth.uid());
  r      public.cine_rooms%rowtype;
  v_cost int := public._cine_machine_price(v_uid);
  v_tick int;
  v_id   bigint;
begin
  select * into r from public.cine_rooms where id = p_room and user_id = v_uid and type = 'arcade' and built_at is not null;
  if not found then raise exception 'Salle d''arcade inconnue : %', p_room using errcode = '22023'; end if;
  if p_x is null or p_y is null or not public._cine_floor_cell(r.w, r.h, p_x, p_y) then
    return public._cine_refuse(v_uid, 'bad_cell', 'Cette case n''est pas dans la salle.');
  end if;
  if exists (select 1 from public.cine_machines where room_id = p_room and x = p_x and y = p_y) then
    return public._cine_refuse(v_uid, 'cell_taken', 'Il y a déjà une machine ici.');
  end if;
  select tickets into v_tick from public.profiles where id = v_uid;
  if v_tick < v_cost then
    return public._cine_refuse(v_uid, 'insufficient_tickets', format('Il te manque %s billets.', v_cost - v_tick));
  end if;
  update public.profiles set tickets = tickets - v_cost where id = v_uid;
  insert into public.cine_machines (user_id, room_id, x, y) values (v_uid, p_room, p_x, p_y) returning id into v_id;
  perform public._cine_settle(v_uid, now());
  return jsonb_build_object('ok', true, 'machine_id', v_id, 'cost', v_cost, 'state', public._cine_state_json(v_uid, now()));
end;
$$;

-- ---------- Déplacer une machine sur une case libre de sa salle : {ok:true, state} | refus : bad_cell, cell_taken
create function public.cine_move_machine(p_machine bigint, p_x integer, p_y integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := public._cine_begin(auth.uid());
  m     public.cine_machines%rowtype;
  r     public.cine_rooms%rowtype;
begin
  select * into m from public.cine_machines where id = p_machine and user_id = v_uid;
  if not found then raise exception 'Machine inconnue : %', p_machine using errcode = '22023'; end if;
  select * into r from public.cine_rooms where id = m.room_id;
  if p_x is null or p_y is null or not public._cine_floor_cell(r.w, r.h, p_x, p_y) then
    return public._cine_refuse(v_uid, 'bad_cell', 'Cette case n''est pas dans la salle.');
  end if;
  if exists (select 1 from public.cine_machines where room_id = m.room_id and x = p_x and y = p_y and id <> p_machine) then
    return public._cine_refuse(v_uid, 'cell_taken', 'Il y a déjà une machine ici.');
  end if;
  update public.cine_machines set x = p_x, y = p_y where id = p_machine;
  return jsonb_build_object('ok', true, 'state', public._cine_state_json(v_uid, now()));
end;
$$;

-- =====================================================================
-- 5. OUTILS ADMIN (contrôle is_admin dans _require_admin)
-- =====================================================================
create function public.cine_admin_add_tickets(p_amount integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := public._cine_begin(public._require_admin());
begin
  if p_amount is null or p_amount < 1 or p_amount > 10000000 then
    raise exception 'Montant invalide : entre 1 et 10 000 000' using errcode = '22023';
  end if;
  update public.profiles set tickets = tickets + p_amount where id = v_uid;
  return public._cine_state_json(v_uid, now());
end;
$$;

create function public.cine_admin_finish_build()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := public._cine_begin(public._require_admin());
begin
  update public.cine_states set build_ends_at = now() where user_id = v_uid and build_ends_at is not null;
  perform public._cine_settle(v_uid, now());
  return public._cine_state_json(v_uid, now());
end;
$$;

-- Repartir de la base (couloir + guichet) ; Billets, gemmes et collection intacts
create function public.cine_admin_reset()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := public._cine_begin(public._require_admin());
begin
  delete from public.cine_states where user_id = v_uid;          -- pièces et machines partent avec (cascade)
  perform public._cine_settle(v_uid, now());
  return public._cine_state_json(v_uid, now());
end;
$$;

-- =====================================================================
-- 6. DROITS
-- =====================================================================
revoke execute on function public._cine_param(text), public._cine_bonus_pct(uuid), public._cine_screen_income(uuid, bigint),
  public._cine_rate(uuid), public._cine_accrued(numeric, timestamptz, timestamptz, timestamptz),
  public._cine_gem_price(timestamptz, timestamptz), public._cine_room_offer(uuid, text, text), public._cine_machine_price(uuid),
  public._cine_door(int, int, int, int, int, int, int, int), public._cine_floor_cell(int, int, int, int),
  public._cine_apply_build(uuid, timestamptz), public._cine_settle(uuid, timestamptz), public._cine_begin(uuid),
  public._cine_state_json(uuid, timestamptz), public._cine_refuse(uuid, text, text)
  from public, anon, authenticated;

revoke execute on function public.cine_get_state(), public.cine_collect(),
  public.cine_build_room(text, text, integer, integer, boolean), public.cine_upgrade_box_office(),
  public.cine_finish_with_gems(integer), public.cine_set_film(bigint, integer),
  public.cine_buy_machine(bigint, integer, integer), public.cine_move_machine(bigint, integer, integer),
  public.cine_admin_add_tickets(integer), public.cine_admin_finish_build(), public.cine_admin_reset()
  from public, anon, authenticated;

grant execute on function public.cine_get_state(), public.cine_collect(),
  public.cine_build_room(text, text, integer, integer, boolean), public.cine_upgrade_box_office(),
  public.cine_finish_with_gems(integer), public.cine_set_film(bigint, integer),
  public.cine_buy_machine(bigint, integer, integer), public.cine_move_machine(bigint, integer, integer),
  public.cine_admin_add_tickets(integer), public.cine_admin_finish_build(), public.cine_admin_reset()
  to authenticated;
