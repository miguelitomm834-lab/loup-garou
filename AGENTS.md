# Loup-Garou — Découpage multi-agents

## Prérequis avant de lancer quoi que ce soit

- [ ] `schema_loupgarou.sql` exécuté sans erreur dans Supabase
- [ ] `SUPABASE_URL` et `SUPABASE_ANON` renseignés dans `app.html`
- [ ] Une partie test complète jouée à 6 comptes (nuit → jour → vote → fin)
- [ ] Repo Git initialisé et poussé sur GitHub

Tant que ces 4 cases ne sont pas cochées, les agents travaillent à l'aveugle.

## Structure du repo

```
loup-garou/
├── index.html              → landing (agent LANDING)
├── app.html                → client de jeu (agent CLIENT)
├── supabase/
│   ├── schema.sql          → schéma initial
│   └── migrations/         → (agent MOTEUR)
├── tests/                  → (agent QA)
└── CLAUDE.md
```

## Règle d'or

Chaque agent possède **ses fichiers, et rien d'autre**. Un agent qui a besoin
d'une modif dans le périmètre d'un autre ouvre une note dans `NOTES.md`
au lieu d'éditer le fichier. C'est ce qui évite les conflits de merge.

| Agent   | Possède                    | Branche          |
|---------|----------------------------|------------------|
| MOTEUR  | `supabase/**`              | `feat/moteur`    |
| CLIENT  | `app.html`                 | `feat/client`    |
| LANDING | `index.html`               | `feat/landing`   |
| QA      | `tests/**`                 | `feat/qa`        |

Lance chacun dans son propre worktree pour qu'ils tournent vraiment en parallèle :

```bash
git worktree add ../lg-moteur  -b feat/moteur
git worktree add ../lg-client  -b feat/client
git worktree add ../lg-landing -b feat/landing
git worktree add ../lg-qa      -b feat/qa
```

---

## Contexte commun (à mettre dans `CLAUDE.md`)

```markdown
# Loup-Garou en ligne

Jeu de loups-garous multijoueur en ligne, en français.
Stack : HTML/CSS/JS vanilla (aucun build), Supabase (Postgres + Realtime + Auth),
déployé sur Netlify.

## Règles non négociables

1. AUCUNE logique de jeu côté client. Distribution des rôles, résolution de nuit,
   comptage des votes et conditions de victoire vivent dans des fonctions
   Postgres SECURITY DEFINER. Le client affiche, il ne décide pas.
2. Les rôles sont dans `roles_joueurs`, protégée par RLS. Ne jamais exposer
   cette table autrement que par les policies existantes.
3. Pas de framework, pas de bundler. Un fichier HTML autonome par écran.
4. Interface et code en français : noms de tables, de fonctions, de variables.
5. Ne jamais écrire « Thiercelieux » nulle part — marque déposée. Le jeu
   s'appelle « Loup-Garou en ligne ».

## Design tokens (imposés par la landing existante)

--nuit:#0f0d1a  --panneau:#14102a  --carte:#1c1731  --bord:#241c3f
--texte:#e9e2f2 --doux:#9b8cc0     --faible:#6b5f8a
--violet:#8d6fe0 --violet-clair:#b5a3ef --or:#ffd9a0 --sang:#c4566e

Titres : Cormorant Garamond italique 700. Texte : Nunito 400/700/800/900.

## Périmètre

Tu ne modifies que les fichiers listés dans ton prompt. Pour tout besoin
hors périmètre, ajoute une ligne dans NOTES.md et continue.
```

---

## Agent MOTEUR — `supabase/`

```
Tu travailles sur le backend Postgres du jeu. Lis CLAUDE.md et supabase/schema.sql.
Tu ne modifies QUE des fichiers dans supabase/. Chaque changement va dans un
fichier de migration daté sous supabase/migrations/, jamais dans schema.sql.

Tâches, dans l'ordre :

1. pg_cron. Aujourd'hui c'est l'hôte qui appelle resoudre_phase() quand son
   chrono tombe à zéro : si son onglet se ferme, la partie se fige. Écris une
   fonction avancer_parties_en_retard() qui parcourt toutes les parties dont
   phase_fin_le < now() et statut hors ('lobby','terminee'), et appelle
   resoudre_phase sur chacune. Planifie-la toutes les 10 secondes via pg_cron.

2. Résolution anticipée. Si tous les joueurs concernés ont agi, la phase ne
   devrait pas attendre le chrono. Ajoute tous_ont_agi(p_partie) qui vérifie
   que chaque vivant avec un pouvoir a une ligne dans actions_nuit pour le
   cycle courant, et que chaque vivant a voté pendant la phase de vote.
   Appelle resoudre_phase automatiquement quand c'est vrai.

3. Abandons. Un joueur qui ferme son onglet en pleine partie bloque tout.
   Ajoute une colonne vu_le sur joueurs_partie, mise à jour par un heartbeat,
   et considère absent quiconque n'a rien envoyé depuis 90 secondes. Un absent
   ne compte pas dans tous_ont_agi et ne bloque pas la résolution.

4. Anti-triche. Vérifie qu'aucune fonction n'expose un rôle en dehors des
   policies. Teste explicitement : un villageois qui fait
   select * from roles_joueurs ne doit voir que sa propre ligne.

Chaque migration doit être réexécutable sans casser une base déjà migrée.
```

## Agent CLIENT — `app.html`

```
Tu travailles sur le client de jeu. Lis CLAUDE.md et app.html.
Tu ne modifies QUE app.html. Le fichier reste autonome : pas d'import,
pas de build, styles dans le <style> en tête.

Tâches, dans l'ordre :

1. Reconnexion. Si l'onglet se ferme et revient, le joueur doit retrouver sa
   partie en cours. Stocke l'id de partie, et au chargement, si le joueur est
   dans une partie non terminée, replonge-le dedans directement.

2. Heartbeat. Envoie un signal de présence toutes les 30 secondes
   (voir NOTES.md pour le nom exact de la fonction côté MOTEUR) et affiche
   un point gris sur le jeton des joueurs absents.

3. Journal de partie. Aujourd'hui les morts apparaissent sans explication.
   Ajoute au chat Village des messages système à chaque changement de phase :
   qui a été dévoré, qui a été lynché, avec quel décompte. Style : italique,
   couleur --or, ton de conteur. Exemple : « Au petit matin, on retrouve
   Bastien devant sa porte. Il était Villageois. »

4. Mobile. Sous 600px, le cercle du village devient illisible. Repense la
   disposition en gardant la lune centrale comme repère de phase.

5. Accessibilité. Focus clavier visible sur les jetons sélectionnables,
   navigation au clavier dans le cercle, aria-live sur les changements de phase.

Ne touche à aucune règle de jeu : tout passe par les RPC existantes.
```

## Agent LANDING — `index.html`

```
Tu travailles sur la page d'accueil. Lis CLAUDE.md et index.html.
Tu ne modifies QUE index.html. Ne casse rien de la mise en page existante,
elle est validée.

Tâches, dans l'ordre :

1. Branche les CTA. Tous les liens #app pointent dans le vide. « Jouer
   maintenant », « Se connecter » et « Jouer pour les découvrir » doivent
   mener à app.html.

2. Classement réel. Le top 5 est en dur dans le HTML. Lis la vue `classement`
   de Supabase via le client JS et affiche les vrais joueurs. Prévois l'état
   vide : « La saison vient de commencer. Le sommet est libre. »

3. Compteur de joueurs. « 2 847 joueurs en ligne · 134 parties en cours » est
   inventé. Compte les vraies parties en statut lobby/nuit/jour/vote. Si les
   chiffres sont bas au lancement, affiche seulement les parties en cours.

4. Traductions. Le sélecteur FR/EN/ES/DE ne fait rien. Implémente-le avec un
   objet de traductions et un attribut data-i18n sur les textes. Mémorise le
   choix. La qualité des traductions compte : fais-les toi-même, pas de
   machine à traduire.

5. Poids. Les 4 images en base64 pèsent 215 Ko sur 262 Ko. Sors-les en
   fichiers .webp dans /assets et référence-les normalement.

Les 18 rôles verrouillés n'existent pas encore côté jeu : garde-les présentés
comme à venir, ne promets rien de faux.
```

## Agent QA — `tests/`

```
Tu écris les tests. Lis CLAUDE.md et supabase/schema.sql.
Tu ne modifies QUE des fichiers sous tests/. Tu ne corriges aucun bug toi-même :
tu documentes ce qui casse dans tests/RESULTATS.md.

Écris un script Node qui utilise @supabase/supabase-js pour simuler une partie
complète avec 8 comptes de test, et vérifie :

1. Distribution : 2 loups pour 8 joueurs, une voyante, une sorcière, un
   chasseur, le reste en villageois. Aucun rôle en double parmi les uniques.
2. Étanchéité : avec la session d'un villageois, select sur roles_joueurs
   ne renvoie qu'une ligne. Avec celle d'un loup, uniquement les loups.
   C'est le test le plus important du fichier.
3. Cycle complet : les loups dévorent, la sorcière sauve, personne ne meurt.
   Puis nuit 2 sans potion, la victime meurt bien.
4. Vote : égalité parfaite = aucun mort. Majorité stricte = le bon joueur meurt.
5. Chasseur : sa mort déclenche bien le statut 'chasseur' et bloque la partie
   jusqu'au tir.
6. Amoureux : Cupidon lie un loup et un villageois, tous les autres meurent,
   le camp vainqueur doit être 'amoureux'.
7. Victoires : dernier loup mort = village gagne. Loups >= villageois = loups.

Lance chaque test sur une partie neuve. Nettoie derrière toi.
```

---

## Ordre de merge

QA d'abord (il ne casse rien), puis MOTEUR, puis CLIENT, puis LANDING.
Relance la suite de tests après chaque merge dans main.
