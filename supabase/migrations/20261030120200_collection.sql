-- =====================================================================
-- COLLECTION : une ligne par (joueur, film) obtenu. Écrite uniquement par open_booster().
-- Le client lit sa collection et ne peut changer que le suivi (« à voir » / « vu »).
-- rank / rarity = valeurs au dernier tirage du film (comme addToCol) : elles ne bougent pas si le catalogue est
-- reclassé. La note TMDB (rating) vient de films.vote_average par jointure.
-- =====================================================================

create table public.collection (
  user_id           uuid    not null references public.profiles (id) on delete cascade,
  film_id           integer not null references public.films (id),
  count             integer not null default 1 check (count >= 1),
  rarity            public.rarity not null,
  rank              integer not null check (rank between 1 and 30000),
  is_to_watch       boolean not null default false,    -- cœur
  is_watched        boolean not null default false,    -- check
  first_obtained_at timestamptz not null default now(),
  last_obtained_at  timestamptz not null default now(),
  primary key (user_id, film_id),
  check (not (is_to_watch and is_watched))             -- exclusion mutuelle, comme setFilmStatus()
);

create index collection_film_idx on public.collection (film_id);

alter table public.collection enable row level security;

-- Pas d'insert ni de delete pour le client ; update limité aux deux colonnes de suivi
revoke all on table public.collection from anon, authenticated;
grant select on table public.collection to authenticated;
grant update (is_to_watch, is_watched) on table public.collection to authenticated;
grant all on table public.collection to service_role;

create policy "collection: lecture de sa collection"
  on public.collection for select to authenticated
  using (user_id = (select auth.uid()));

create policy "collection: suivi de ses films"
  on public.collection for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Top Films : uniquement des films possédés, chacun dans une seule case (cases vides = null)
create function public.check_top_films()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from unnest(new.top_films) as t(film_id)
    where t.film_id is not null
    group by t.film_id having count(*) > 1
  ) then
    raise exception 'Un film ne peut occuper qu''une case du Top Films';
  end if;
  if exists (
    select 1 from unnest(new.top_films) as t(film_id)
    where t.film_id is not null
      and not exists (select 1 from public.collection c where c.user_id = new.id and c.film_id = t.film_id)
  ) then
    raise exception 'Le Top Films ne peut contenir que des films de ta collection';
  end if;
  return new;
end;
$$;

revoke execute on function public.check_top_films() from public, anon, authenticated;

create trigger profiles_check_top_films
  before update of top_films on public.profiles
  for each row execute function public.check_top_films();
