-- =====================================================================
-- OPENINGS : historique des boosters ouverts (une ligne par booster). Écrit uniquement par open_booster().
-- Sert à l'audit du tirage et aux statistiques. Le paiement et le tirage se font dans la même transaction :
-- si l'ouverture échoue, rien n'est débité (le remboursement est automatique).
-- =====================================================================

create table public.openings (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  payment     text not null check (payment in ('free', 'reels')),   -- booster gratuit ou temps restant payé en bobines
  cost_reels  integer not null default 0 check (cost_reels >= 0),
  cost_gems   integer not null default 0 check (cost_gems >= 0),    -- gemmes converties pour compléter les bobines
  demo        boolean not null default false,                       -- mode démo admin : cartes non ajoutées à la collection
  film_ids    integer[] not null check (cardinality(film_ids) = 5), -- ordre de révélation (la plus rare en dernier)
  rarities    public.rarity[] not null check (cardinality(rarities) = 5),   -- rareté de chaque carte au tirage
  created_at  timestamptz not null default now()
);

create index openings_user_idx on public.openings (user_id, created_at desc);

alter table public.openings enable row level security;

revoke all on table public.openings from anon, authenticated;
grant select on table public.openings to authenticated;
grant all on table public.openings to service_role;

create policy "openings: lecture de ses ouvertures"
  on public.openings for select to authenticated
  using (user_id = (select auth.uid()));
