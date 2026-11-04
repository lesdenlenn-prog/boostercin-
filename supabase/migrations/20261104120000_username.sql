-- =====================================================================
-- PSEUDO (morceau 4e) : format, unicité sans tenir compte des majuscules, vérification de disponibilité
--   - 3 à 20 caractères : lettres (accents latins compris), chiffres, _ - .
--   - unique sans tenir compte des majuscules (« Léo » et « léo » ne peuvent pas coexister)
--   - username_available(p_username) : le client vérifie un pseudo avant d'envoyer le code e-mail
--   - seul un compte rattaché à un e-mail peut avoir un pseudo (pas de pseudos « réservés » par des comptes anonymes jetables)
-- Aucun nouveau droit d'écriture : le client modifiait déjà profiles.username (grant par colonne du schéma initial).
-- Les règles du format sont recopiées dans index.html (USERNAME_RE) : les garder identiques.
-- =====================================================================

-- 1. Pseudos déjà enregistrés qui ne respectent pas les nouvelles règles : remis à null (le joueur en choisira un autre)
update public.profiles
   set username = null
 where username is not null
   and username !~ '^[A-Za-z0-9À-ÖØ-öø-ÿ_.-]{3,20}$';

-- Comptes anonymes : pas de pseudo (sinon la policy restrictive du point 4 bloquerait aussi leur vitrine)
update public.profiles p
   set username = null
 where p.username is not null
   and exists (select 1 from auth.users u where u.id = p.id and u.is_anonymous);

-- Doublons (majuscules près) : le compte le plus ancien garde le pseudo
update public.profiles p
   set username = null
 where p.username is not null
   and exists (select 1 from public.profiles q
                where lower(q.username) = lower(p.username)
                  and (q.created_at, q.id) < (p.created_at, p.id));

-- 2. Format (remplace l'ancienne contrainte « 1 à 24 caractères ») et unicité
alter table public.profiles drop constraint if exists profiles_username_check;
alter table public.profiles add constraint profiles_username_format
  check (username ~ '^[A-Za-z0-9À-ÖØ-öø-ÿ_.-]{3,20}$');

create unique index profiles_username_lower_key on public.profiles (lower(username));

-- 3. Disponibilité d'un pseudo (le joueur ne peut lire que son propre profil : la fonction lit tous les pseudos pour lui)
--    true = format valide et pseudo libre (ou déjà le sien) ; ne renvoie rien d'autre qu'un booléen
create function public.username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(p_username ~ '^[A-Za-z0-9À-ÖØ-öø-ÿ_.-]{3,20}$', false)
     and not exists (select 1
                       from public.profiles
                      where lower(username) = lower(p_username)
                        and id is distinct from auth.uid());
$$;

revoke execute on function public.username_available(text) from public, anon, authenticated;
grant execute on function public.username_available(text) to authenticated;

-- 4. Le compte connecté est-il rattaché à un e-mail ? (lu dans auth.users : ne dépend pas de la fraîcheur du jeton)
create function public._account_linked()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from auth.users
                  where id = auth.uid()
                    and email is not null and email <> ''
                    and not is_anonymous);
$$;

revoke execute on function public._account_linked() from public, anon, authenticated;
grant execute on function public._account_linked() to authenticated;   -- évaluée dans la policy ci-dessous (droits de l'appelant)

-- Policy restrictive (s'ajoute en ET à « profiles: modification de son profil ») :
-- un compte anonyme peut toujours modifier sa vitrine, mais pas se donner un pseudo
create policy "profiles: pseudo réservé aux comptes rattachés"
  on public.profiles as restrictive for update to authenticated
  using (true)
  with check (username is null or public._account_linked());
