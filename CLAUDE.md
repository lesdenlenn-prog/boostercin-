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
- 5 pages en carrousel : Magasin, Marché, Accueil, Vidéothèque, Amis. HUD profil + ressources.
- Révélations Légendaire / Ultra très travaillées : **n'animer que `transform` et `opacity`**.

### Appels TMDB restants côté client
Hors tirage, le client appelle encore TMDB avec la clé du joueur : détails d'un film (`getDetails`), recherche de
personnes (`searchPeople`) et de films (`searchMovies`). Il faudra un proxy serveur (Edge Function) ou une autre solution,
puisqu'aucune clé TMDB ne doit être dans `index.html`.

## Migration Supabase

Objectif : comptes Supabase, tirage et économie côté serveur, client en lecture seule sur les cartes.

1. **Schéma** : `supabase/migrations/` (`profiles`, `films`, `collection`, `openings`, avec RLS).
2. Import du catalogue `films` depuis TMDB (script serveur, clé TMDB dans `.env`).
3. Fonction Postgres `open_booster()` (`security definer`) : énergie/paiement + tirage + collection + `openings`,
   dans une seule transaction (échec = rien de débité). Fonctions admin (ressources, reset, mode démo) qui vérifient
   `profiles.is_admin`.
4. Client : connexion anonyme au lancement, puis rattachement à un e-mail par code OTP
   (`updateUser({ email })` puis `verifyOtp({ type: 'email_change' })` : même `user.id`, la collection est conservée).

### Décisions
- Collections localStorage existantes : on repart de zéro, pas d'import.
- Correspondance localStorage → Supabase : `wallet` → `profiles.reels/gems`, `energy` → `profiles.energy_n/energy_t`,
  `boostersOuverts` → `profiles.boosters_opened`, `demo` → `profiles.demo_mode` (admin seulement),
  `collection[id].rating` → `films.vote_average`, `isToWatch/isWatched` → `collection.is_to_watch/is_watched`.
- Admin : `profiles.is_admin`, posé à la main dans le SQL Editor, jamais modifiable par le client.

## Règles

- **Secrets** : les clés sont dans `.env` (ignoré par git). Ne jamais afficher ni lire son contenu dans la conversation.
  Seule la *publishable key* Supabase peut apparaître dans `index.html` ; jamais la secret/service_role key ni la clé TMDB.
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
- Code : suivre le style d'`index.html` (commentaires en français, JS vanilla, pas de dépendance de build).
