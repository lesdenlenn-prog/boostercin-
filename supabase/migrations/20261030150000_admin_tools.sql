-- =====================================================================
-- OUTILS DE TEST (admin seulement) : remplacent les boutons du Magasin, « RESET RESSOURCES »,
-- le mode démo et « Supprimer toutes les cartes » des réglages (v53).
-- Chaque fonction agit sur le compte de l'admin connecté et renvoie son nouvel état (_state_json).
-- Un joueur non admin reçoit l'erreur 42501 « Réservé à l'admin ».
-- =====================================================================

-- ---------- Interne : identifiant de l'admin connecté, ou erreur
create function public._require_admin()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Connexion requise' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and is_admin) then
    raise exception 'Réservé à l''admin' using errcode = '42501';
  end if;
  return v_uid;
end;
$$;

-- ---------- Magasin : +N bobines ou +N gemmes (boutons « +100 »)
create function public.admin_add_resource(p_kind text, p_amount integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._require_admin();
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then
    raise exception 'Montant invalide : entre 1 et 1 000 000' using errcode = '22023';
  end if;
  if p_kind = 'reels' then
    update public.profiles set reels = reels + p_amount where id = v_uid;
  elsif p_kind = 'gems' then
    update public.profiles set gems = gems + p_amount where id = v_uid;
  else
    raise exception 'Ressource inconnue : % (reels ou gems)', p_kind using errcode = '22023';
  end if;
  return public._state_json(v_uid, now());
end;
$$;

-- ---------- RESET RESSOURCES : 0 bobine, 0 gemme, 0 booster gratuit, le compte à rebours repart de maintenant
create function public.admin_reset_resources()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._require_admin();
begin
  update public.profiles set reels = 0, gems = 0, energy_n = 0, energy_t = now() where id = v_uid;
  return public._state_json(v_uid, now());
end;
$$;

-- ---------- Mode démo : cotes DEMO_P, cartes non ajoutées à la collection
create function public.admin_set_demo(p_on boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._require_admin();
begin
  update public.profiles set demo_mode = coalesce(p_on, false) where id = v_uid;
  return public._state_json(v_uid, now());
end;
$$;

-- ---------- Supprimer toutes les cartes de sa collection (le Top Films, qui n'a plus de films possédés, est vidé)
-- L'historique openings est conservé.
create function public.admin_reset_collection()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public._require_admin();
  v_deleted integer;
begin
  delete from public.collection where user_id = v_uid;
  get diagnostics v_deleted = row_count;
  update public.profiles set top_films = '{}' where id = v_uid;
  return jsonb_build_object('deleted', v_deleted, 'state', public._state_json(v_uid, now()));
end;
$$;

-- ---------- Droits
revoke execute on function public._require_admin() from public, anon, authenticated;

revoke execute on function public.admin_add_resource(text, integer) from public, anon;
revoke execute on function public.admin_reset_resources() from public, anon;
revoke execute on function public.admin_set_demo(boolean) from public, anon;
revoke execute on function public.admin_reset_collection() from public, anon;
-- ouvertes à authenticated : le contrôle is_admin se fait dans la fonction (un joueur reçoit « Réservé à l'admin »)
grant execute on function public.admin_add_resource(text, integer) to authenticated;
grant execute on function public.admin_reset_resources() to authenticated;
grant execute on function public.admin_set_demo(boolean) to authenticated;
grant execute on function public.admin_reset_collection() to authenticated;
