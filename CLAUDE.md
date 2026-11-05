# Booster ciné

Jeu web mobile (français) : on ouvre des boosters de 5 cartes « films » et on remplit sa Vidéothèque.
Tout le jeu tient dans un seul fichier, `index.html` (HTML + CSS + JS vanilla, aucun build).
Déployé sur Vercel depuis ce dépôt GitHub (branche `main`).
**Le code v53 fait foi** : en cas de doute entre une description et `index.html`, c'est le code qui a raison.

## État actuel du jeu (v53, tout en localStorage, à migrer vers Supabase)

### Catalogue et tirage
- 30 000 films classés par `vote_count` TMDB décroissant (`/discover/movie?sort_by=vote_count.desc`, 20 films/page, 1 500 pages).
  TMDB limite `/discover` à 500 pages : le code découpe en 3 segments avec `vote_count.lte`
  (seuil = votes du dernier film du segment précédent).
- Raretés et probabilités (`TIERS`) :

  | id          | Libellé          | Rangs           | Proba   |
  |-------------|------------------|-----------------|---------|
  | `ultra`     | Ultra-légendaire | 1 – 15          | 0,05 %  |
  | `legendary` | Légendaire       | 16 – 300        | 0,5 %   |
  | `epic`      | Épique           | 301 – 1 800     | 2,5 %   |
  | `rare`      | Rare             | 1 801 – 6 000   | 9 %     |
  | `uncommon`  | Peu commune      | 6 001 – 15 000  | 28 %    |
  | `common`    | Commune          | 15 001 – 30 000 | 59,95 % |

- Booster = 5 cartes, la 5e jamais Commune, pas de doublon dans un booster, triées pour révéler la plus rare en dernier.
- Mode démo (cotes élevées `DEMO_P`, cartes non ajoutées à la collection) : doit devenir **réservé à l'admin**.

### Économie (à rendre 100 % serveur)
- Boosters gratuits : 6 max, 6 à la 1re connexion, +1 toutes les 4 h ; timer en pause quand c'est plein ;
  horodaté (`energy = {n, t}`).
- Sans booster gratuit : on paie le temps restant en bobines, 15 bobines par heure entamée.
  Payer en bobines relance un cycle complet de 4 h (`energy.t` = maintenant).
- Bobines manquantes : conversion de gemmes par lot de 5 bobines entamé = 2 gemmes.
- Remboursement si l'ouverture échoue.
- Les boutons du Magasin (+100 bobines, +100 gemmes) et « RESET RESSOURCES » sont des outils de test :
  **réservés à l'admin, jamais accessibles aux joueurs**.

### Données par joueur
- collection : par film, `count`, rareté au moment du tirage, `rank`, note TMDB (`rating`),
  `isToWatch` / `isWatched` (exclusifs l'un de l'autre, modifiables par le joueur).
- Profil : `topFilms` (4 ids de films possédés, cases vides = null, un film par case), `favs` (2 genres, réalisateur et
  acteur favoris `{id, name, photo}`), `wishlist` (3 films `{id, title, year, poster}`, non possédés),
  `boostersOuverts` (statistique).

### Interface (ne pas modifier sans demande)
- 6 pages en carrousel : Magasin, Marché, Accueil, Vidéothèque, Cinéma, Amis. HUD profil + ressources (Billets sur la page Cinéma).
- Révélations Légendaire / Ultra très travaillées : **n'animer que `transform` et `opacity`**.

### Appels TMDB restants côté client
Depuis le 4d, le client n'appelle plus TMDB directement : détails d'un film (`getDetails`) et personnes
(`loadSuggestions`, `searchPeople`) passent par l'Edge Function `tmdb`. Les images restent servies par
`image.tmdb.org` (pas de clé). Aucune clé TMDB ne doit être dans `index.html`.

## Migration Supabase

Objectif : comptes Supabase, tirage et économie côté serveur, client en lecture seule sur les cartes.

1. **Schéma** (fait, appliqué) : `supabase/migrations/` (`profiles`, `films`, `collection`, `openings`, avec RLS).
2. Import du catalogue `films` : `node scripts/import-films.mjs [--test]` (Node, aucune dépendance npm).
   Lit `TMDB_API_KEY`, `SUPABASE_URL`, `SUPABASE_SECRET_KEY` dans `.env`. Cache de reprise dans `.import-cache/AAAA-MM/`.
   Fiches en upsert par lots, puis rangs/raretés remplacés d'un coup par `apply_film_ranks()` (service_role seulement),
   car `films.rank` est unique. Ne jamais supprimer de film : ceux sortis du classement passent à `rank = null`.
   Les tranches de rareté sont dupliquées dans le script : les garder identiques à `TIERS`.
3. `20261030140000_open_booster.sql` : `open_booster(p_use_gems)` (énergie/paiement + tirage + collection + `openings`,
   une seule transaction, échec = rien de débité) et `get_booster_state()` (lecture seule : soldes, énergie, prix).
   Refus = `{ok:false, reason:'need_gems'|'insufficient_funds', message, state}` ; rappeler avec `true` si le joueur
   accepte la conversion. Helpers internes `_energy_refresh`, `_booster_cost`, `_gems_for_reels`, `_pick_rarity`,
   `_state_json` (execute révoqué pour tous). Les cotes TIERS/DEMO_P sont dupliquées dans `_pick_rarity`.
   Tests manuels : `supabase/tests/open_booster.sql`. Reste à faire : fonctions admin (ressources, reset, mode démo)
   qui vérifient `profiles.is_admin`.
4. Client (`index.html`), découpé en morceaux testés en local (Live Server) avant chaque push :
   - **4a + 4b** (fusionnés : indissociables) : supabase-js 2.118.0 (CDN jsDelivr), session anonyme au démarrage
     (écran `#boot`), soldes/énergie/statistiques via `get_booster_state` → `applyState()`, collection chargée depuis
     `collection` + `films` dans `colCache` (pagination par 1 000), ouverture via `open_booster` (`payForBooster`),
     suivi à voir/vu écrit dans `collection`, outils admin (`.admin-only`, masqués si `is_admin` est faux).
     La clé TMDB devient facultative (bouton « Clé TMDB » de la Vidéothèque) : synopsis, personnes, liste de souhaits.
     Anciennes clés localStorage (`wallet`, `energy`, `collection`, `boostersOuverts`, `demo`, `rarity_model`) supprimées.
   - **4c** : Top Films, favoris, liste de souhaits lus/écrits dans `profiles` (`loadProfile`, `saveProfile` ; en cas de
     refus, on relit le serveur). Liste de souhaits : 30 films les plus populaires (`films` par `rank`) et recherche via
     `search_films()` (migration `20261030160000_film_search.sql` : `films.original_title`, extension `unaccent`).
     Le script d'import remplit `original_title` (cache `.import-cache/AAAA-MM-v2`). Plus aucun seuil TMDB côté client.
   - **4d** : Edge Function `supabase/functions/tmdb/index.ts` (déployée depuis le tableau de bord, secret
     `TMDB_API_KEY`, « Verify JWT » activé + `withSupabase({ auth: 'user' })`). Liste blanche : `/movie/{id}`,
     `/search/person`, `/person/popular`, `/trending/person/week`, paramètres validés. Le client appelle
     `sb.functions.invoke('tmdb', { body: { path, params } })` dans `tmdb()`. Plus d'écran ni de clé TMDB côté client.
     Toute modification de la fonction doit être recollée dans l'éditeur du tableau de bord puis redéployée.
   - **4e** : écran Paramètres (engrenage du Profil, `#acctModal`, section « COMPTE » du script). Sauvegarde = pseudo +
     e-mail, `updateUser({ email })` puis `verifyOtp({ type: 'email_change' })` : même `user.id`, le pseudo est écrit après
     vérification. « J'ai déjà un compte » = `signInWithOtp({ shouldCreateUser: false })` puis `verifyOtp({ type: 'email' })`,
     puis `reloadPlayer()` ; pas de fusion (avertissement si le compte anonyme a des cartes). Déconnexion
     `signOut({ scope: 'local' })`, réservée aux comptes rattachés. Constantes `OTP_LENGTH` (8, = réglage « Email OTP Length »),
     `OTP_TTL`, `OTP_RESEND` (60 s). **`EMAIL_READY = false`** tant que le SMTP et les modèles d'e-mail (« Change email
     address » et « Magic link » avec `{{ .Token }}`) ne sont pas configurés : sauvegarde, connexion et rappel masqués.
     Rappel « Sauvegarde ta collection » après le 3e booster (localStorage `saveNudgeAt`). Migration
     `20261104120000_username.sql` (appliquée) : pseudo 3–20 caractères (`USERNAME_RE` côté client, à garder identique),
     unique sans tenir compte des majuscules, `username_available()`, policy restrictive : pas de pseudo sur un compte anonyme.
     4a à 4d ne doivent dépendre d'aucun e-mail.

5. **Mode Cinéma** (jeu de gestion idle), découpé en C0 → C5, chaque étape testée avant commit :
   - C0 (validé) : modèle de données et équilibrage ci-dessous.
   - **C1** (appliqué, testé) : `20261104140000_cinema.sql`. Équilibrage dans `cinema_levels` (coût, durée, revenu, bonus,
     salles requises par niveau de `screen`/`arcade`/`box_office`/`popcorn`/`vip`/`sound`), `cinema_params` (`cap_hours` 12,
     `empty_mult` 0,25, `gem_minutes` 10) et `cinema_rarity` (multiplicateurs) : lus par le client, modifiables sans migration.
     Joueur : `profiles.tickets` (Billets), `cinemas` (taux, caisse `banked`/`accrue_from`, `last_collect_at`, chantier),
     `cinema_screens` (film unique par salle, FK vers `collection`), `cinema_upgrades`. `_cinema_settle` fait le point à
     chaque appel (chantier échu, revenu au taux d'avant, nouveau taux). API : `get_cinema_state`, `collect_cash`,
     `start_build(kind)`, `finish_build_with_gems(p_max_gems)`, `set_screening(screen, film)` (film déplacé s'il est déjà
     projeté), `admin_add_tickets`, `admin_finish_build`, `admin_reset_cinema`. Tests : `supabase/tests/cinema.sql`.
   - **C2** (fait) : onglet « Cinéma » (6e page, avant Amis ; barre resserrée sous 360 px), HUD Billets + gemmes sans profil
     ni bobines, section « CINÉMA » du script : `applyCinema` (dates du serveur ramenées à l'horloge du téléphone via
     `server_now`), caisse qui monte localement jusqu'à `full_at`, jauge 12 h (`scaleX`), `collect_cash`, plan SVG simple
     `cinePlanSvg` (20 emplacements, hall, guichet, arcade, équipements, chantier + minuteur), outils admin. État relu à chaque
     visite de la page et au retour dans l'appli ; chantier échu → relecture du serveur.
   - **C3** (fait) : menu Salles / Arcade / Guichet / Équipements (`renderCineCards`, `nextBuild`) lu dans `cinema_levels` et
     `cinema_params` (`loadCineConfig`, une fois) ; refus affichés sur place, `start_build` revérifie. Bandeau du chantier
     (minuteur, prix du moment = règle de `_cinema_gem_price`) ; « Terminer » ouvre la fenêtre de paiement (`ctx: 'cine'`)
     puis `finish_build_with_gems(prix affiché)`.
   - **C4** (fait) : un appui sur une salle du plan (`[data-screen]`, aussi au clavier) ouvre la modale de sélection du Top
     Films en mode `pickTarget = 'cine'` : étiquette « ×multiplicateur · Salle n » (`cinema_rarity`, lu par `loadCineConfig`),
     bouton « Retirer » si la salle projette un film ; `chooseScreenFilm` → `set_screening` (film déplacé s'il était ailleurs).
   - **C5** (fait) : plan cartoon (`cinePlanSvg`, `cpScreen`, `cpEmpty`, `cpSite`, `cpHall`, `cpStreet`) : salles (moquette,
     fauteuils, écran, faisceau qui scintille si un film passe, affiche encadrée de sa rareté), béton pour les emplacements libres,
     chantier (hachures, plots, marteau), hall délabré → carrelage (guichet 1+) → plantes (3+) → dorures (5+), guichet à vitres,
     arcade néon, équipements dessinés, enseigne « CINÉMA » à ampoules (éteinte tant que le hall est délabré). Animations
     `.cp-*` en opacity/transform, en pause hors de la page Cinéma, coupées avec prefers-reduced-motion.

### Décisions
- Collections localStorage existantes : on repart de zéro, pas d'import.
- Correspondance localStorage → Supabase : `wallet` → `profiles.reels/gems`, `energy` → `profiles.energy_n/energy_t`,
  `boostersOuverts` → `profiles.boosters_opened`, `demo` → `profiles.demo_mode` (admin seulement),
  `collection[id].rating` → `films.vote_average`, `isToWatch/isWatched` → `collection.is_to_watch/is_watched`.
- Admin : `profiles.is_admin`, posé à la main dans le SQL Editor, jamais modifiable par le client.

### À décider plus tard
- Le catalogue contient des courts-métrages (ex. « Chassé-croisé », Looney Tunes de 1951). Envisager un filtre de durée
  (`with_runtime.gte` sur `/discover`) lors d'une prochaine mise à jour du catalogue : à appliquer aussi dans le jeu
  tant que le client calcule ses propres classements.

## Règles

- **Secrets** : les clés sont dans `.env` (ignoré par git). Ne jamais afficher ni lire son contenu dans la conversation.
  Seule la *publishable key* Supabase peut apparaître dans `index.html` ; jamais la secret/service_role key ni la clé TMDB.
  **Ne jamais afficher un secret, ni demander à l'utilisateur d'en coller un dans le chat** : s'il en manque un, lui demander
  de l'ajouter lui-même dans `.env` (seuls les *noms* des variables peuvent être listés, `grep -o '^[A-Z_]*=' .env`).
- **Confirmation obligatoire avant toute action irréversible** : suppression de données (joueurs réels, cartes, tables,
  colonnes), reset de la base ou du cinéma d'un vrai joueur, changement des réglages Auth ou de la sécurité (RLS, grants,
  policies, clés, URL autorisées, SMTP). Seule exception : les joueurs de test créés par Claude, supprimés sans demander.
- **Accès Supabase en autonomie** (migrations, tests, Edge Functions, secrets des fonctions) via `.env` :
  `SUPABASE_DB_URL` (base) et `SUPABASE_ACCESS_TOKEN` (CLI / Management API, projet `tubjlfbqadwgclhbfuco`, ex.
  `npx supabase functions deploy tmdb --project-ref tubjlfbqadwgclhbfuco`, `npx supabase secrets set … --project-ref …`
  avec les valeurs lues depuis `.env`, jamais écrites en clair dans la commande affichée).
- **Le client n'écrit jamais de cartes** : pas de `insert`/`delete` sur `collection` ni `openings`, aucun droit d'écriture sur
  `films`. Toute écriture de cartes, de bobines/gemmes, d'énergie ou de `is_admin`/`demo_mode` passe par des fonctions
  `security definer`. Le client ne peut modifier que `profiles.username/top_films/favs/wishlist` et
  `collection.is_to_watch/is_watched` (grants par colonne).
- **Le projet Supabase n'expose pas automatiquement les nouvelles tables et active la RLS d'office.** Chaque migration doit :
  - `enable row level security` sur chaque table ;
  - faire des `grant` explicites et minimaux (tables, colonnes, types **et** fonctions) à `anon`, `authenticated`, `service_role` ;
  - écrire les policies RLS correspondantes ;
  - pour chaque fonction : `revoke execute ... from public, anon, authenticated` puis `grant` seulement à qui doit l'appeler,
    et `set search_path = ''` (noms qualifiés `public.`, `auth.`) sur les fonctions `security definer`.
- Les utilisateurs anonymes ont aussi le rôle `authenticated` (claim JWT `is_anonymous`).
- Dans les policies, écrire `(select auth.uid())` plutôt que `auth.uid()` (évalué une seule fois).
- Migrations : `supabase/migrations/AAAAMMJJHHMMSS_nom.sql`. Ne jamais modifier une migration déjà appliquée : en ajouter une nouvelle.
- **Claude applique lui-même les migrations et les tests** (plus de copier-coller dans le SQL Editor) :
  - connexion : `SUPABASE_DB_URL` dans `.env` (session pooler), chargée sans jamais afficher sa valeur
    (`set -a; . ./.env; set +a`) et masquée dans les sorties ;
  - avant d'appliquer : vérifier l'état réel (`npx supabase migration list --db-url "$SUPABASE_DB_URL"`, tables et fonctions
    existantes), puis `npx supabase db push --dry-run --db-url …`, puis `db push --yes`. L'historique
    `supabase_migrations.schema_migrations` est à jour depuis le 4/11/2026 (migrations 1 à 8 marquées appliquées par
    `migration repair`) : ne plus appliquer de SQL hors `db push` ;
  - tests : créer un joueur de test via l'API admin (`SUPABASE_URL` + `SUPABASE_SECRET_KEY`, e-mail confirmé), exécuter
    chaque bloc de `supabase/tests/*.sql` en tant que ce joueur (`set local role authenticated` + `request.jwt.claims`),
    vérifier chaque résultat attendu, puis **toujours** supprimer le joueur de test (même en cas d'échec) ;
  - rendre compte : migrations appliquées, tests réussis / ratés.
- Code : suivre le style d'`index.html` (commentaires en français, JS vanilla, pas de dépendance de build).
