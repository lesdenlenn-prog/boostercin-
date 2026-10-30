-- =====================================================================
-- OUVERTURE D'UN BOOSTER (remplace drawBooster() et l'économie côté client, v53)
--   get_booster_state()      : soldes, énergie, prochain booster gratuit, prix actuel (lecture seule)
--   open_booster(p_use_gems) : énergie → paiement → tirage → collection → openings, en UNE transaction
--                              (toute erreur annule tout : rien n'est débité)
-- Les fonctions _xxx sont internes : appelables uniquement depuis les deux fonctions ci-dessus.
-- =====================================================================

-- ---------- Énergie à l'instant p_now (= refreshEnergy) : 6 max, +1 toutes les 4 h, timer en pause quand c'est plein
create function public._energy_refresh(p_n integer, p_t timestamptz, p_now timestamptz, out n integer, out t timestamptz)
language plpgsql
stable
set search_path = ''
as $$
declare
  gained integer;
begin
  n := least(greatest(coalesce(p_n, 0), 0), 6);
  t := least(p_t, p_now);                                   -- horodatage dans le futur : on repart de maintenant
  if n >= 6 then
    t := p_now;                                             -- plein : timer en pause
  else
    gained := floor(extract(epoch from (p_now - t)) / 14400);   -- 4 h = 14 400 s
    if gained > 0 then
      n := least(6, n + gained);
      t := case when n >= 6 then p_now else t + gained * interval '4 hours' end;   -- on garde l'avance du cycle en cours
    end if;
  end if;
end;
$$;

-- ---------- Prix du temps restant (= timerCost) : 15 bobines par heure entamée, 1 h minimum
create function public._booster_cost(p_t timestamptz, p_now timestamptz)
returns integer
language sql
stable
set search_path = ''
as $$
  select greatest(1, ceil(extract(epoch from (p_t + interval '4 hours' - p_now)) / 3600))::integer * 15;
$$;

-- ---------- Gemmes pour N bobines manquantes (= gemsForReels) : lot de 5 bobines entamé = 2 gemmes
create function public._gems_for_reels(p_missing integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select (ceil(greatest(p_missing, 0) / 5.0) * 2)::integer;
$$;

-- ---------- Rareté tirée au sort (= pickTier) : cotes TIERS, ou DEMO_P en mode démo ; sans Commune pour la 5e carte
create function public._pick_rarity(p_demo boolean, p_no_common boolean)
returns public.rarity
language plpgsql
volatile
set search_path = ''
as $$
declare
  ids    public.rarity[] := array['ultra', 'legendary', 'epic', 'rare', 'uncommon', 'common']::public.rarity[];
  p      float8[] := array[0.0005, 0.005, 0.025, 0.09, 0.28, 0.5995];    -- TIERS
  p_d    float8[] := array[0.15, 0.20, 0.25, 0.18, 0.12, 0.10];          -- DEMO_P
  w      float8[] := case when p_demo then p_d else p end;
  total  float8 := 0;
  r      float8;
  last_i integer;
begin
  for i in 1..6 loop
    if not (p_no_common and ids[i] = 'common') then total := total + w[i]; end if;
  end loop;
  r := random() * total;                                    -- cotes renormalisées sans la Commune, comme dans le jeu
  for i in 1..6 loop
    if p_no_common and ids[i] = 'common' then continue; end if;
    r := r - w[i];
    last_i := i;
    if r < 0 then return ids[i]; end if;
  end loop;
  return ids[last_i];
end;
$$;

-- ---------- État du joueur à l'instant p_now (sans rien écrire)
create function public._state_json(p_uid uuid, p_now timestamptz)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  prof       public.profiles%rowtype;
  e          record;
  v_cost     integer := 0;
  v_missing  integer := 0;
  v_gem_cost integer := 0;
begin
  select * into prof from public.profiles where id = p_uid;
  if not found then raise exception 'Profil introuvable'; end if;
  select * into e from public._energy_refresh(prof.energy_n, prof.energy_t, p_now);
  if e.n = 0 then
    v_cost := public._booster_cost(e.t, p_now);
    v_missing := greatest(0, v_cost - prof.reels);
    v_gem_cost := public._gems_for_reels(v_missing);
  end if;
  return jsonb_build_object(
    'reels', prof.reels,
    'gems', prof.gems,
    'energy', jsonb_build_object(
      'n', e.n,
      'max', 6,
      'period_ms', 14400000,
      'next_free_at', case when e.n >= 6 then null else e.t + interval '4 hours' end,   -- null = plein, timer en pause
      'ms_to_next', case when e.n >= 6 then 0
                         else greatest(0, floor(extract(epoch from (e.t + interval '4 hours' - p_now)) * 1000))::bigint end),
    'price', jsonb_build_object(
      'free', e.n > 0,
      'cost_reels', v_cost,                                 -- 0 si un booster gratuit est disponible
      'missing_reels', v_missing,
      'gem_cost', v_gem_cost,                               -- gemmes à convertir pour compléter
      'can_open', e.n > 0 or prof.reels >= v_cost or prof.gems >= v_gem_cost),
    'boosters_opened', prof.boosters_opened,
    'demo_mode', prof.demo_mode and prof.is_admin,
    'is_admin', prof.is_admin,
    'server_now', p_now                                     -- pour caler l'horloge du client sur celle du serveur
  );
end;
$$;

-- =====================================================================
-- API joueur
-- =====================================================================

create function public.get_booster_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Connexion requise' using errcode = '42501'; end if;
  return public._state_json(v_uid, now());
end;
$$;

/* Réponse :
   - succès : {ok:true, payment:'free'|'reels', cost_reels, cost_gems, demo, cards:[5 cartes, la plus rare en dernier], state}
     carte = {id, title, year, poster, rarity, rank, votes, overview, rating, is_new, count}
   - refus (rien n'est écrit) : {ok:false, reason:'need_gems'|'insufficient_funds', message, state}
     need_gems : rappeler open_booster(true) si le joueur accepte de convertir state.price.gem_cost gemmes */
create function public.open_booster(p_use_gems boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_now      timestamptz := now();
  prof       public.profiles%rowtype;
  e          record;
  v_n        integer;
  v_t        timestamptz;
  v_demo     boolean;
  v_payment  text;
  v_cost     integer := 0;
  v_missing  integer := 0;
  v_gem_cost integer := 0;
  v_rarity   public.rarity;
  v_film     integer;
  v_drawn    integer[] := '{}';                             -- films tirés, dans l'ordre du tirage
  v_owned    integer[];
  v_ids      integer[];
  v_rars     public.rarity[];
  v_cards    jsonb;
begin
  if v_uid is null then raise exception 'Connexion requise' using errcode = '42501'; end if;

  -- verrou : deux ouvertures simultanées du même joueur passent l'une après l'autre
  select * into prof from public.profiles where id = v_uid for update;
  if not found then raise exception 'Profil introuvable'; end if;
  v_demo := prof.demo_mode and prof.is_admin;

  -- 1. énergie à l'heure du serveur
  select * into e from public._energy_refresh(prof.energy_n, prof.energy_t, v_now);
  v_n := e.n;
  v_t := e.t;

  -- 2. paiement : gratuit → bobines → gemmes (si accepté) → refus
  if v_n > 0 then
    v_payment := 'free';
    if v_n >= 6 then v_t := v_now; end if;                  -- on quitte le « plein » : le compte à rebours démarre
    v_n := v_n - 1;
  else
    v_cost := public._booster_cost(v_t, v_now);
    if prof.reels < v_cost then
      v_missing := v_cost - prof.reels;
      v_gem_cost := public._gems_for_reels(v_missing);
      if prof.gems < v_gem_cost then
        return jsonb_build_object('ok', false, 'reason', 'insufficient_funds',
          'message', format('Fonds insuffisants : il te manque %s bobines, soit %s gemmes à convertir. Tu n''as que %s gemme(s).',
                            v_missing, v_gem_cost, prof.gems),
          'state', public._state_json(v_uid, v_now));
      end if;
      if not coalesce(p_use_gems, false) then
        return jsonb_build_object('ok', false, 'reason', 'need_gems',
          'message', format('Bobines insuffisantes : ouvrir maintenant coûte %s bobines, il t''en manque %s. Convertir %s gemmes pour compléter ?',
                            v_cost, v_missing, v_gem_cost),
          'state', public._state_json(v_uid, v_now));
      end if;
    end if;
    v_payment := 'reels';
    v_t := v_now;                                           -- payer en bobines relance un cycle complet de 4 h
  end if;

  -- 3. tirage : 5 cartes, la 5e jamais Commune, pas de doublon, uniquement des films avec affiche
  for i in 1..5 loop
    v_rarity := public._pick_rarity(v_demo, i = 5);
    select f.id into v_film
      from public.films f
     where f.rarity = v_rarity and f.poster_path is not null and f.id <> all (v_drawn)
     order by random()
     limit 1;
    if not found then raise exception 'Aucun film disponible pour la rareté %', v_rarity; end if;
    v_drawn := v_drawn || v_film;
  end loop;

  -- ordre de révélation : la plus rare en dernier (à rareté égale, ordre du tirage)
  select array_agg(f.id order by f.rarity, d.ord), array_agg(f.rarity order by f.rarity, d.ord)
    into v_ids, v_rars
    from unnest(v_drawn) with ordinality as d(id, ord)
    join public.films f on f.id = d.id;

  v_owned := array(select c.film_id from public.collection c where c.user_id = v_uid and c.film_id = any (v_drawn));

  -- 4. collection (sauf mode démo) : count +1, rareté et rang du tirage
  if not v_demo then
    insert into public.collection as c (user_id, film_id, rarity, rank)
    select v_uid, f.id, f.rarity, f.rank
      from public.films f
     where f.id = any (v_drawn)
    on conflict (user_id, film_id) do update
      set count = c.count + 1, rarity = excluded.rarity, rank = excluded.rank, last_obtained_at = v_now;
  end if;

  -- 5. soldes, énergie, statistique (boosters_opened compte aussi en mode démo, comme dans le jeu)
  update public.profiles
     set energy_n = v_n,
         energy_t = v_t,
         reels = prof.reels + v_missing - v_cost,           -- conversion : exactement les bobines manquantes → 0
         gems = prof.gems - v_gem_cost,
         boosters_opened = prof.boosters_opened + 1
   where id = v_uid;

  insert into public.openings (user_id, payment, cost_reels, cost_gems, demo, film_ids, rarities)
  values (v_uid, v_payment, v_cost, v_gem_cost, v_demo, v_ids, v_rars);

  -- 6. les 5 cartes, prêtes pour la pile
  select jsonb_agg(jsonb_build_object(
           'id', f.id, 'title', f.title, 'year', f.year, 'poster', f.poster_path,
           'rarity', f.rarity, 'rank', f.rank, 'votes', f.vote_count,
           'overview', f.overview, 'rating', f.vote_average,
           'is_new', not (f.id = any (v_owned)),
           'count', coalesce(c.count, 0))
         order by f.rarity, d.ord)
    into v_cards
    from unnest(v_drawn) with ordinality as d(id, ord)
    join public.films f on f.id = d.id
    left join public.collection c on c.user_id = v_uid and c.film_id = f.id;

  return jsonb_build_object('ok', true, 'payment', v_payment, 'cost_reels', v_cost, 'cost_gems', v_gem_cost,
                            'demo', v_demo, 'cards', v_cards, 'state', public._state_json(v_uid, v_now));
end;
$$;

-- ---------- Droits : fonctions internes fermées à tous, API ouverte aux seuls joueurs connectés (anonymes compris)
revoke execute on function public._energy_refresh(integer, timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public._booster_cost(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public._gems_for_reels(integer) from public, anon, authenticated;
revoke execute on function public._pick_rarity(boolean, boolean) from public, anon, authenticated;
revoke execute on function public._state_json(uuid, timestamptz) from public, anon, authenticated;

revoke execute on function public.get_booster_state() from public, anon;
revoke execute on function public.open_booster(boolean) from public, anon;
grant execute on function public.get_booster_state() to authenticated;
grant execute on function public.open_booster(boolean) to authenticated;
