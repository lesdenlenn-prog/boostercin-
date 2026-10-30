-- =====================================================================
-- PROFILS : un par compte (anonyme ou e-mail), créé automatiquement.
-- Le client lit son profil et ne peut modifier que les champs « vitrine » (pseudo, top films, favoris, souhaits).
-- Bobines, gemmes, énergie, compteur de boosters, admin et mode démo : écrits uniquement par des fonctions serveur.
-- =====================================================================

create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  username         text check (char_length(username) between 1 and 24),
  -- économie (100 % serveur)
  reels            integer     not null default 0 check (reels >= 0),                 -- bobines
  gems             integer     not null default 0 check (gems >= 0),                  -- gemmes
  energy_n         smallint    not null default 6 check (energy_n between 0 and 6),   -- boosters gratuits dispo (6 à la 1re connexion)
  energy_t         timestamptz not null default now(),                               -- début du compte à rebours en cours (4 h)
  boosters_opened  integer     not null default 0 check (boosters_opened >= 0),      -- statistique « boosters ouverts »
  -- vitrine (modifiable par le joueur)
  top_films        integer[]   not null default '{}' check (cardinality(top_films) <= 4),   -- 4 cases, null = case vide ; films possédés (vérifié dans la migration collection)
  favs             jsonb       not null default '{"genres":[null,null],"director":null,"actor":null}'::jsonb
                   check (jsonb_typeof(favs) = 'object'),                            -- director / actor = {id, name, photo}
  wishlist         jsonb       not null default '[null,null,null]'::jsonb
                   check (jsonb_typeof(wishlist) = 'array' and jsonb_array_length(wishlist) <= 3),   -- {id, title, year, poster} ou null
  -- outils de test (réservés à l'admin, jamais modifiables par le client)
  is_admin         boolean     not null default false,
  demo_mode        boolean     not null default false check (not demo_mode or is_admin),   -- cotes DEMO_P, cartes non ajoutées
  created_at       timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Droits : rien par défaut, puis le strict nécessaire
revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (username, top_films, favs, wishlist) on table public.profiles to authenticated;
grant all on table public.profiles to service_role;

create policy "profiles: lecture de son profil"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()));

create policy "profiles: modification de son profil"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Création automatique du profil à l'inscription (y compris connexion anonyme)
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
