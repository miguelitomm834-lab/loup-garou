# Loup-Garou en ligne

Jeu de loups-garous multijoueur en ligne, en français.
Stack : HTML/CSS/JS vanilla (aucun build), Supabase (Postgres + Realtime + Auth),
déployé sur Netlify.

## Règles non négociables

1. Aucune logique de jeu côté client. Distribution des rôles, résolution de nuit,
   comptage des votes et conditions de victoire vivent dans des fonctions
   Postgres SECURITY DEFINER. Le client affiche, il ne décide pas.
2. Les rôles sont dans `roles_joueurs`, protégée par RLS. Ne jamais exposer
   cette table autrement que par les policies existantes.
3. Pas de framework, pas de bundler. Un fichier HTML autonome par écran.
4. Interface et code en français : noms de tables, de fonctions, de variables.
5. Toute modification du schéma passe par un nouveau fichier dans
   supabase/migrations/, jamais par une édition de schema.sql.
6. Ne jamais écrire « Thiercelieux » nulle part — marque déposée.

## Design tokens (imposés par la landing existante)

--nuit:#0f0d1a  --panneau:#14102a  --carte:#1c1731  --bord:#241c3f
--texte:#e9e2f2 --doux:#9b8cc0     --faible:#6b5f8a
--violet:#8d6fe0 --violet-clair:#b5a3ef --or:#ffd9a0 --sang:#c4566e

Titres : Cormorant Garamond italique 700. Texte : Nunito 400/700/800/900.

## Tests

Toute modification du schéma doit repasser `tests/tests_complets.sql` au vert
avant d'être commitée. Voir README.md pour la procédure.
