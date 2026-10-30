/* =====================================================================
   IMPORT DU CATALOGUE : les 30 000 films les plus votés de TMDB → table public.films (Supabase)

   node scripts/import-films.mjs --test   mode test : 60 films (3 pages), pour vérifier dans Table Editor
   node scripts/import-films.mjs          import complet (à relancer chaque mois)

   Même classement que le jeu (section 3 d'index.html) : /discover/movie, vote_count.desc, fr-FR, sans adulte,
   segments de 500 pages enchaînés avec vote_count.lte = votes du dernier film du segment précédent.
   Les films à égalité pile sur un seuil reviennent dans le segment suivant : on ne garde que leur 1re apparition,
   et on continue jusqu'à 30 000 films uniques (rangs 1 à 30 000 sans trou).

   Reprise : chaque page TMDB est gardée dans .import-cache/AAAA-MM/. Relancer la commande repart de là ;
   un nouveau mois repart de zéro (classement frais).
   Écriture : 1. upsert des fiches par lots de 1 000 (sans doublon, même relancé)
              2. apply_film_ranks() : tous les rangs et raretés remplacés d'un coup, en une transaction.
   Aucune clé n'est jamais affichée.
   ===================================================================== */

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const TEST = process.argv.includes('--test');
const TARGET = TEST ? 60 : 30000;            // films à classer
const SEG_PAGES = 500;                       // limite de pages de /discover par requête
const MAX_PAGES = 1700;                      // garde-fou (1 500 pages + marge pour les doublons aux seuils)
const CONCURRENCY = 4;                       // requêtes TMDB en parallèle
const MIN_GAP = 40;                          // ms entre deux requêtes TMDB (≈ 25/s, sous la limite d'environ 40/s)
const BATCH = 1000;                          // lignes par upsert Supabase

// Mêmes tranches que TIERS dans index.html : [id, premier rang, dernier rang]
const TIERS = [
  ['ultra', 1, 15], ['legendary', 16, 300], ['epic', 301, 1800],
  ['rare', 1801, 6000], ['uncommon', 6001, 15000], ['common', 15001, 30000]
];
const rarityOf = rank => TIERS.find(([, a, b]) => rank >= a && rank <= b)[0];

class Fatal extends Error {}                 // erreur qu'un nouvel essai ne corrigera pas
const sleep = ms => new Promise(r => setTimeout(r, ms));
const nf = n => n.toLocaleString('fr-FR');

/* ---------- Clés (.env) : on vérifie leur présence, jamais leur contenu ---------- */
try{ process.loadEnvFile(path.join(ROOT, '.env')); }
catch{ stop('Fichier .env introuvable à la racine du projet.'); }
const missing = ['TMDB_API_KEY', 'SUPABASE_URL', 'SUPABASE_SECRET_KEY'].filter(k => !process.env[k]?.trim());
if(missing.length) stop('Variable(s) manquante(s) dans .env : ' + missing.join(', '));

const TMDB_KEY = process.env.TMDB_API_KEY.trim();
const SB_URL = process.env.SUPABASE_URL.trim().replace(/\/+$/, '');
const SB_KEY = process.env.SUPABASE_SECRET_KEY.trim();
const sbHeaders = {apikey: SB_KEY, 'Content-Type': 'application/json'};
if(!SB_KEY.startsWith('sb_')) sbHeaders.Authorization = 'Bearer ' + SB_KEY;   // ancienne clé service_role (JWT)

function stop(msg){
  console.error('\n✖ ' + msg);
  process.exit(1);
}

/* ---------- Réessais automatiques (délai croissant : 1 s, 2 s, 4 s… 30 s max) ---------- */
async function withRetry(label, fn, tries = 7){
  for(let i = 1; ; i++){
    try{ return await fn(); }
    catch(e){
      if(e instanceof Fatal || i >= tries) throw e;
      const wait = e.wait ?? Math.min(30000, 1000 * 2 ** (i - 1));
      const why = e.name === 'TimeoutError' ? 'délai dépassé' : e.message;   // jamais l'URL (elle peut contenir la clé TMDB)
      console.log(`  ↻ ${label} : ${why}. Nouvel essai dans ${Math.round(wait / 1000)} s (${i}/${tries - 1})`);
      await sleep(wait);
    }
  }
}
const retryable = (msg, wait) => Object.assign(new Error(msg), {wait});

/* ---------- TMDB ---------- */
let nextAt = 0;
async function throttle(){
  const now = Date.now(), at = Math.max(now, nextAt);
  nextAt = at + MIN_GAP;
  if(at > now) await sleep(at - now);
}

function discover(page, lte){
  const url = new URL('https://api.themoviedb.org/3/discover/movie');
  const params = {sort_by:'vote_count.desc', include_adult:'false', language:'fr-FR', page};
  if(lte != null) params['vote_count.lte'] = lte;
  Object.entries(params).forEach(([k, v]) => url.searchParams.set(k, v));
  const headers = {accept: 'application/json'};
  if(TMDB_KEY.length > 40) headers.Authorization = 'Bearer ' + TMDB_KEY;   // jeton d'accès (v4), comme dans le jeu
  else url.searchParams.set('api_key', TMDB_KEY);                          // clé API (v3)

  return withRetry(`TMDB page ${page}`, async () => {
    await throttle();
    const r = await fetch(url, {headers, signal: AbortSignal.timeout(20000)});
    if(r.status === 401) throw new Fatal('Clé TMDB refusée (401). Vérifie TMDB_API_KEY dans .env.');
    if(r.status === 429) throw retryable('limite de requêtes TMDB (429)', (+r.headers.get('retry-after') || 2) * 1000);
    if(r.status >= 500) throw retryable(`TMDB indisponible (${r.status})`);
    if(!r.ok) throw new Fatal(`TMDB a répondu ${r.status} pour la page ${page}.`);
    return r.json();
  });
}

// Page globale g (1, 2, 3…) → page locale dans son segment, avec le seuil du segment. Mise en cache sur disque.
const CACHE = path.join(ROOT, '.import-cache', new Date().toISOString().slice(0, 7));
let fromCache = 0;
async function getPage(g, lte){
  const file = path.join(CACHE, `page-${String(g).padStart(4, '0')}.json`);
  try{
    const c = JSON.parse(await readFile(file, 'utf8'));
    if(c.lte === lte){ fromCache++; return c.films; }
  }catch{}
  const d = await discover((g - 1) % SEG_PAGES + 1, lte);
  const films = (d.results || []).map(m => ({
    id: m.id, title: m.title, release_date: m.release_date, poster_path: m.poster_path,
    overview: m.overview, vote_count: m.vote_count, vote_average: m.vote_average
  }));
  if(!films.length) throw new Fatal(`TMDB n'a renvoyé aucun film pour la page ${g}.`);
  await writeFile(file, JSON.stringify({lte, films}));
  return films;
}

/* ---------- Supabase (API REST, clé secrète) ---------- */
async function sb(pathname, body, label, prefer){
  return withRetry(label, async () => {
    const r = await fetch(SB_URL + pathname, {
      method: 'POST', body: JSON.stringify(body), signal: AbortSignal.timeout(120000),
      headers: prefer ? {...sbHeaders, Prefer: prefer} : sbHeaders
    });
    // Corps lu en texte : vide avec Prefer: return=minimal (201/204), JSON sinon
    const text = await r.text();
    let data = null;
    if(text.trim()){ try{ data = JSON.parse(text); }catch{ data = {message: text.slice(0, 300)}; } }
    if(r.ok) return data;
    const err = data || {};
    const detail = `HTTP ${r.status}` + (err.code ? ` [${err.code}]` : '') + ` : ${err.message || r.statusText || 'réponse vide'}`
                 + (err.details ? ` — ${err.details}` : '') + (err.hint ? ` (${err.hint})` : '');
    if(r.status === 401 || r.status === 403) throw new Fatal(`Clé Supabase refusée (${detail}). Vérifie SUPABASE_SECRET_KEY dans .env.`);
    if(err.code === 'PGRST202') throw new Fatal('Fonction apply_film_ranks introuvable : applique d\'abord la migration 20261030130000_apply_film_ranks.sql.');
    if(r.status >= 500 || r.status === 429) throw retryable(`Supabase indisponible (${detail})`);
    throw new Fatal(`Supabase a refusé la requête « ${label} » : ${detail}`);
  });
}

/* ---------- 1. Classement TMDB ---------- */
async function fetchRanking(){
  await mkdir(CACHE, {recursive: true});
  const films = new Map();                   // id → film, dans l'ordre du classement (1re apparition)
  let lte = null, g = 1, dupes = 0;
  while(films.size < TARGET){
    if(g > MAX_PAGES) throw new Fatal(`Seulement ${nf(films.size)} films uniques après ${MAX_PAGES} pages.`);
    const segEnd = Math.ceil(g / SEG_PAGES) * SEG_PAGES;
    const last = Math.min(segEnd, g + CONCURRENCY - 1);   // un lot ne déborde jamais sur le segment suivant
    const nums = Array.from({length: last - g + 1}, (_, i) => g + i);
    const pages = await Promise.all(nums.map(n => getPage(n, lte)));
    for(const page of pages) for(const m of page){
      if(films.size >= TARGET) break;
      if(films.has(m.id)) dupes++; else films.set(m.id, m);
    }
    if(last === segEnd) lte = pages.at(-1).at(-1).vote_count;   // seuil du segment suivant
    if(last % 50 === 0 || films.size >= TARGET)
      console.log(`  Pages TMDB : ${nf(last)} · films : ${nf(films.size)} / ${nf(TARGET)}` + (fromCache ? ` (dont ${nf(fromCache)} pages en cache)` : ''));
    g = last + 1;
  }
  if(dupes) console.log(`  ${nf(dupes)} doublon(s) aux seuils ignoré(s).`);
  return [...films.values()];
}

/* ---------- 2 + 3. Écriture dans Supabase ---------- */
async function main(){
  console.log(TEST ? `MODE TEST : ${TARGET} films seulement.\n` : `IMPORT COMPLET : ${nf(TARGET)} films.\n`);

  console.log('1/3 Classement TMDB…');
  const ranked = await fetchRanking();

  console.log(`\n2/3 Envoi des fiches à Supabase (lots de ${nf(BATCH)})…`);
  const now = new Date().toISOString();
  const rows = ranked.map(m => ({
    id: m.id, title: m.title || '(sans titre)', year: (m.release_date || '').slice(0, 4),
    poster_path: m.poster_path || null, overview: m.overview || '',
    vote_count: m.vote_count || 0, vote_average: m.vote_average || 0, updated_at: now
  }));
  for(let i = 0; i < rows.length; i += BATCH){
    const lot = rows.slice(i, i + BATCH);
    await sb('/rest/v1/films?on_conflict=id', lot, `lot ${i / BATCH + 1}`, 'resolution=merge-duplicates,return=minimal');
    console.log(`  ${nf(i + lot.length)} / ${nf(rows.length)}`);
  }

  console.log('\n3/3 Rangs et raretés…');
  const ranks = ranked.map((m, i) => ({id: m.id, rank: i + 1, rarity: rarityOf(i + 1)}));
  const n = await sb('/rest/v1/rpc/apply_film_ranks', {ranks}, 'classement');
  console.log(`  ${nf(n)} films classés.`);

  const count = Object.fromEntries(TIERS.map(([id]) => [id, 0]));
  ranks.forEach(r => count[r.rarity]++);
  console.log('\n✔ Terminé. Répartition :');
  TIERS.forEach(([id]) => count[id] && console.log(`  ${id.padEnd(10)} ${nf(count[id]).padStart(7)}`));
}

main().catch(e => {
  const why = e instanceof Fatal ? e.message : (e.name === 'TimeoutError' ? 'délai dépassé' : e.message);
  stop(why + '\nRelance la même commande : le script reprendra où il s\'est arrêté.');
});
