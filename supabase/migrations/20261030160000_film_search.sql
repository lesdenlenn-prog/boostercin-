-- =====================================================================
-- RECHERCHE DANS LE CATALOGUE (liste de souhaits)
--   films.original_title : titre original (rempli par le script d'import), pour trouver « Le Parrain » en tapant « godfather »
--   search_films(p_query) : 30 films du jeu au plus, sans tenir compte des accents ni des majuscules, du plus voté au moins voté
-- =====================================================================

alter table public.films add column original_title text;

create extension if not exists unaccent with schema extensions;

create function public.search_films(p_query text)
returns table (id integer, title text, year text, poster_path text)
language sql
stable
set search_path = ''
as $$
  -- dictionnaire nommé explicitement : avec search_path vide, unaccent(text) ne le trouverait pas
  with q as (
    select trim(coalesce(p_query, '')) as raw
  ), pat as (
    select '%' || replace(replace(replace(
             extensions.unaccent('extensions.unaccent'::regdictionary, lower(q.raw)),
             '\', '\\'), '%', '\%'), '_', '\_') || '%' as p,   -- % et _ tapés par le joueur = caractères ordinaires
           char_length(q.raw) as len
      from q
  )
  select f.id, f.title, f.year, f.poster_path
    from public.films f, pat
   where pat.len >= 2
     and f.rank is not null and f.poster_path is not null              -- uniquement les films du jeu
     and (extensions.unaccent('extensions.unaccent'::regdictionary, lower(f.title)) like pat.p
          or extensions.unaccent('extensions.unaccent'::regdictionary, lower(coalesce(f.original_title, ''))) like pat.p)
   order by f.rank
   limit 30;
$$;

revoke execute on function public.search_films(text) from public, anon;
grant execute on function public.search_films(text) to authenticated;
