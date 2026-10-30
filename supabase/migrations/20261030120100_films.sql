-- =====================================================================
-- FILMS : catalogue du jeu (30 000 films les plus votés de TMDB), rempli par un script serveur.
-- Lecture publique, aucune écriture côté client.
-- rank / rarity = null : film sorti du classement (on le garde pour les collections existantes).
-- =====================================================================

-- Ordre de l'enum = ordre de rareté croissant (permet order by rarity)
create type public.rarity as enum ('common', 'uncommon', 'rare', 'epic', 'legendary', 'ultra');

grant usage on type public.rarity to anon, authenticated, service_role;

create table public.films (
  id            integer primary key,                 -- identifiant TMDB
  title         text    not null,
  year          text,                                -- 'AAAA' (vide si date inconnue)
  poster_path   text,
  overview      text    not null default '',
  vote_count    integer not null default 0,
  vote_average  real    not null default 0,          -- note TMDB /10
  rank          integer unique check (rank between 1 and 30000),
  rarity        public.rarity,
  updated_at    timestamptz not null default now(),
  check ((rank is null) = (rarity is null))
);

-- open_booster() tirera un film au hasard dans une rareté
create index films_rarity_idx on public.films (rarity) where rarity is not null;

alter table public.films enable row level security;

revoke all on table public.films from anon, authenticated;
grant select on table public.films to anon, authenticated;
grant all on table public.films to service_role;

create policy "films: lecture publique"
  on public.films for select to anon, authenticated
  using (true);
