/* =====================================================================
   EDGE FUNCTION « tmdb » : relais vers l'API TMDB pour le jeu
   - La clé TMDB reste sur le serveur (secret TMDB_API_KEY, jamais dans index.html).
   - Seuls les joueurs connectés (comptes anonymes compris) peuvent l'appeler : withSupabase({ auth: 'user' }).
     Laisser aussi « Verify JWT » activé sur la fonction (vérification de la plateforme).
   - Seuls les chemins et paramètres listés dans ROUTES sont relayés ; tout le reste est refusé (400).
   Appel depuis le jeu : sb.functions.invoke('tmdb', { body: { path, params } })
   ===================================================================== */
import { withSupabase } from 'npm:@supabase/server@1';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Validation des paramètres : renvoie la valeur à transmettre, ou null si elle est refusée
const lang = (v: unknown) => typeof v === 'string' && /^[a-z]{2}-[A-Z]{2}$/.test(v) ? v : null;
const page = (max: number) => (v: unknown) => Number.isInteger(+v!) && +v! >= 1 && +v! <= max ? String(+v!) : null;
const query = (v: unknown) => typeof v === 'string' && v.trim().length >= 1 && v.length <= 100 ? v.trim() : null;
const credits = (v: unknown) => v === 'credits' ? v : null;

type Check = (v: unknown) => string | null;
const ROUTES: {re: RegExp, params: Record<string, Check>, fixed?: Record<string, string>}[] = [
  {re: /^\/movie\/\d{1,9}$/,          params: {language: lang, append_to_response: credits}},                    // fiche d'un film
  {re: /^\/search\/person$/,          params: {query, language: lang, page: page(3)}, fixed: {include_adult: 'false'}},
  {re: /^\/person\/popular$/,         params: {language: lang, page: page(5)}},                                   // suggestions
  {re: /^\/trending\/person\/week$/,  params: {language: lang}},
];

const json = (body: unknown, status = 200) => Response.json(body, {status});

const handler = withSupabase({auth: 'user'}, async (req: Request) => {
  if(req.method !== 'POST') return json({error: 'Méthode non autorisée'}, 405);
  const {path, params = {}} = await req.json().catch(() => ({}));
  const route = typeof path === 'string' ? ROUTES.find(r => r.re.test(path)) : undefined;
  if(!route || typeof params !== 'object' || params === null){
    console.warn('Chemin refusé', path);
    return json({error: 'Requête TMDB non autorisée'}, 400);
  }

  const url = new URL('https://api.themoviedb.org/3' + path);
  for(const [k, v] of Object.entries(params as Record<string, unknown>)){
    if(route.fixed && k in route.fixed) continue;                     // imposé par le serveur : la valeur du client est ignorée
    const check = route.params[k];
    const ok = check ? check(v) : null;
    if(ok === null){
      console.warn('Paramètre refusé', path, k);                      // visible dans les logs de la fonction
      return json({error: `Paramètre refusé : ${k}`}, 400);
    }
    url.searchParams.set(k, ok);
  }
  for(const [k, v] of Object.entries(route.fixed || {})) url.searchParams.set(k, v);

  const key = (Deno.env.get('TMDB_API_KEY') || '').trim();
  if(!key) return json({error: 'Clé TMDB absente du serveur'}, 500);
  const headers: Record<string, string> = {accept: 'application/json'};
  if(key.length > 40) headers.Authorization = 'Bearer ' + key;        // jeton d'accès (v4)
  else url.searchParams.set('api_key', key);                          // clé API (v3)

  try{
    const r = await fetch(url, {headers, signal: AbortSignal.timeout(10000)});
    if(r.status === 404) return json({error: 'Introuvable sur TMDB'}, 404);
    if(!r.ok) return json({error: `TMDB indisponible (${r.status})`}, 502);
    return json(await r.json());
  }catch{
    return json({error: 'TMDB injoignable'}, 502);                    // jamais l'URL : elle peut contenir la clé
  }
});

Deno.serve(async (req: Request) => {
  if(req.method === 'OPTIONS') return new Response('ok', {headers: CORS});   // pré-vérification CORS du navigateur
  const res = await handler(req);
  const out = new Response(res.body, res);
  for(const [k, v] of Object.entries(CORS)) out.headers.set(k, v);          // CORS aussi sur les refus (401, 400…)
  return out;
});
