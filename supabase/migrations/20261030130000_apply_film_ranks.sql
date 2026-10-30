-- =====================================================================
-- CLASSEMENT DU CATALOGUE : remplace tous les rangs/raretés d'un coup (script d'import, service_role seulement).
-- rank est unique : envoyés par lots, deux films qui échangent leur rang entreraient en conflit.
-- Ici tout se fait dans une seule transaction : on vide les rangs, puis on pose les nouveaux.
-- Les films sortis du classement gardent leur ligne (rank / rarity = null) pour les collections existantes.
-- ranks = [{"id": 550, "rank": 1, "rarity": "ultra"}, ...]
-- =====================================================================

create function public.apply_film_ranks(ranks jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  n integer;
begin
  update public.films set rank = null, rarity = null where rank is not null;

  update public.films f
     set rank = r.rank, rarity = r.rarity, updated_at = now()
    from jsonb_to_recordset(ranks) as r(id integer, rank integer, rarity public.rarity)
   where f.id = r.id;

  get diagnostics n = row_count;
  if n <> jsonb_array_length(ranks) then
    raise exception 'Classement incomplet : % films mis à jour sur %', n, jsonb_array_length(ranks);   -- tout est annulé
  end if;
  return n;
end;
$$;

revoke execute on function public.apply_film_ranks(jsonb) from public, anon, authenticated;
grant execute on function public.apply_film_ranks(jsonb) to service_role;
