# Loup-Garou en ligne

Jeu de loups-garous multijoueur, jouable dans le navigateur.
HTML/CSS/JS vanilla, Supabase pour le temps réel et la base, déployé sur Netlify.

## Mise en route

### 1. Base de données

Crée un projet sur [supabase.com](https://supabase.com), puis dans **SQL Editor**
exécute `supabase/schema_complet.sql`. Ce fichier contient le schéma initial et
les deux migrations, dans le bon ordre.

Active ensuite le provider **Email** dans Authentication → Providers.

### 2. Clés

Dans `app.html`, remplace les deux constantes en haut du `<script>` :

```js
const SUPABASE_URL  = 'https://ton-projet.supabase.co';
const SUPABASE_ANON = 'ta_cle_anon_public';
```

Elles se trouvent dans Settings → API. La clé `anon public` est faite pour être
exposée côté client : la sécurité repose sur le RLS, pas sur le secret de la clé.

### 3. Déploiement

Netlify → le site se déploie tel quel, il n'y a rien à construire.

## Architecture

```
index.html                     page d'accueil
app.html                       le jeu (5 écrans, autonome)
supabase/schema.sql            schéma initial
supabase/migrations/           correctifs successifs
supabase/schema_complet.sql    tout en un, pour une installation neuve
tests/                         suite de tests SQL
```

Aucune logique de jeu ne vit côté client. La distribution des rôles, la
résolution des nuits, le comptage des votes et les conditions de victoire sont
des fonctions Postgres `SECURITY DEFINER`. Le client affiche, il ne décide pas.

Les rôles sont stockés dans `roles_joueurs`, séparée de `joueurs_partie`, pour
qu'une policy RLS puisse masquer le rôle sans masquer le joueur. Un joueur ne
lit que le sien ; un loup voit sa meute ; tout est révélé en fin de partie.

## Rôles disponibles

Loup-Garou, Villageois, Voyante, Sorcière, Chasseur, Cupidon.

Composition automatique : 2 loups de 6 à 9 joueurs, 3 au-delà. Voyante dès 6
joueurs, Sorcière dès 7, Chasseur dès 8, Cupidon dès 9.

## Tests

La suite tourne sur un PostgreSQL local, sans Supabase :

```bash
createdb lg
psql -d lg -f tests/00_stub_supabase.sql      # simule le schéma auth de Supabase
psql -d lg -f supabase/schema_complet.sql
psql -d lg -f tests/tests_complets.sql
```

21 tests couvrent la distribution des rôles, l'étanchéité du RLS, le cycle
complet, le chasseur, les amoureux, les conditions de victoire et l'inscription.

## Limite connue

Le passage d'une phase à la suivante est déclenché par l'hôte quand son
chronomètre atteint zéro. Si l'hôte ferme son onglet, la partie se fige.
Le correctif — un `pg_cron` qui appelle `resoudre_phase` sur les parties en
retard — est décrit dans AGENTS.md, périmètre de l'agent MOTEUR.

## Nom

Le jeu s'appelle « Loup-Garou en ligne ». « Les Loups-garous de Thiercelieux »
est une marque déposée de l'éditeur Lui-même : les règles d'un jeu ne sont pas
protégeables, le nom et les illustrations le sont. Ne pas l'employer.
