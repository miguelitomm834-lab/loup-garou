# Voix du Narrateur — phrases à enregistrer

Inventaire exhaustif des messages système du narrateur (source : `supabase/migrations/05_narrateur.sql`,
seule migration qui écrit des messages narrateur — fonctions `annoncer_mort`, `annoncer_bilan`, `conclure`,
`libelle_role`). Le jeu tire une variante **au hasard** parmi les 3 de chaque situation : les trois sont
donc toutes à enregistrer.

## Note d'usage pour le comédien

- **Ton** : conteur sombre de veillée. Voix posée, grave, un rien théâtrale — on raconte une histoire de
  loups au coin du feu, on ne commente pas un match. Les annonces de mort sont solennelles, jamais criées ;
  les victoires peuvent s'ouvrir davantage.
- **Ponctuation** : respecter exactement le texte entre guillemets « … » (pauses aux points, souffle aux
  virgules, suspension aux deux-points et aux tirets).
- **Phrases découpées autour d'un nom de joueur** : le pseudo du joueur est dynamique, il ne peut pas être
  enregistré. La phrase est donc coupée en segments qui seront recollés autour du nom par le jeu :
  - `_avant` = segment lu **avant** le nom → terminer sur une intonation **suspendue** (la phrase continue) ;
  - `_milieu` = segment entre **deux** noms (cas des amoureux) → intonation suspendue des deux côtés ;
  - `_apres` = segment lu **après** le nom → attaquer comme une suite de phrase, finir la phrase normalement.
- **Segments finissant par « Il était »** : ils sont immédiatement suivis d'un fichier de rôle
  (`role_*.mp3`, liste en fin de document). Laisser « Il était » **en suspens**, sans conclure.
- **Fichiers de rôle** : un seul mot, avec l'intonation d'une **fin de phrase** (dans le jeu la phrase
  complète est « Il était Voyante. »).

## Convention de nommage

`situation_variante.mp3` — minuscules, underscores, sans accents.
Segments : suffixes `_avant`, `_milieu`, `_apres`. Rôles : `role_<role>.mp3`.
`[NOM]` = pseudo du joueur mort (dynamique), `[AMOUREUX]` = pseudo de son amoureux, `[ROLE]` = fichier de rôle.

---

## 1. Tombée de la nuit

Diffusé quand la partie enchaîne vers une nouvelle nuit. Phrases entièrement statiques.

| Fichier | Phrase exacte |
|---|---|
| `nuit_tombe_1.mp3` | La nuit tombe. Le village ferme ses volets. |
| `nuit_tombe_2.mp3` | Les lampes s'éteignent une à une. Que ceux qui chassent se réveillent. |
| `nuit_tombe_3.mp3` | L'obscurité s'installe. Le village retient son souffle. |

<sub>Fonction source : `conclure`</sub>

## 2. Lever du jour — victime de la nuit (dévoré **ou** empoisonné)

Une même série de phrases sert pour les deux causes « dévoré » et « empoisonné » (le SQL ne les
distingue pas)¹. Structure : `[avant] [NOM] [apres] [ROLE].`

**Variante 1** — « Au petit matin, on retrouve [NOM] devant sa porte. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_matin_1_avant.mp3` | Au petit matin, on retrouve |
| `mort_matin_1_apres.mp3` | devant sa porte. Il était |

**Variante 2** — « Le village s'éveille dans le silence. [NOM] ne se réveillera pas. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_matin_2_avant.mp3` | Le village s'éveille dans le silence. |
| `mort_matin_2_apres.mp3` | ne se réveillera pas. Il était |

**Variante 3** — « On a retrouvé [NOM] à l'aube, la gorge ouverte. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_matin_3_avant.mp3` | On a retrouvé |
| `mort_matin_3_apres.mp3` | à l'aube, la gorge ouverte. Il était |

<sub>Fonction source : `annoncer_mort` (branche `else` : dévoré / empoisonné)</sub>

## 3. Lever du jour — nuit tranquille (personne n'est mort)

Phrases entièrement statiques.

| Fichier | Phrase exacte |
|---|---|
| `nuit_tranquille_1.mp3` | Le soleil se lève sur un village intact. Cette nuit, personne n'a péri. |
| `nuit_tranquille_2.mp3` | Étrangement, tout le monde répond à l'appel ce matin. |
| `nuit_tranquille_3.mp3` | L'aube est douce : aucune victime cette nuit. |

<sub>Fonction source : `annoncer_bilan` (contexte 'matin', aucun mort)</sub>

## 4. Résultat du vote — pendaison

Structure : `[avant] [NOM] [apres] [ROLE].`

**Variante 1** — « Le village a tranché. [NOM] est pendu haut et court. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_lynche_1_avant.mp3` | Le village a tranché. |
| `mort_lynche_1_apres.mp3` | est pendu haut et court. Il était |

**Variante 2** — « La corde se tend. [NOM] n'ira pas plus loin. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_lynche_2_avant.mp3` | La corde se tend. |
| `mort_lynche_2_apres.mp3` | n'ira pas plus loin. Il était |

**Variante 3** — « Sous les huées, [NOM] monte à l'échafaud. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_lynche_3_avant.mp3` | Sous les huées, |
| `mort_lynche_3_apres.mp3` | monte à l'échafaud. Il était |

<sub>Fonction source : `annoncer_mort` (cause 'lynché par le village')</sub>

## 5. Résultat du vote — égalité / pas de majorité (personne ne meurt)

Phrases entièrement statiques.

| Fichier | Phrase exacte |
|---|---|
| `vote_egalite_1.mp3` | Les voix se sont partagées. Le village n'a pas su choisir, et personne ne meurt. |
| `vote_egalite_2.mp3` | Faute de majorité, la corde reste vide aujourd'hui. |
| `vote_egalite_3.mp3` | Le village hésite, se déchire, et finalement épargne tout le monde. |

<sub>Fonction source : `annoncer_bilan` (contexte 'vote', aucun mort)</sub>

## 6. Le chasseur tombe (il lui reste une balle)

Diffusé quand le chasseur vient de mourir et va tirer. `[NOM]` = pseudo du chasseur.
Les variantes 1 et 3 **commencent** par le nom : pas de segment `_avant`.

**Variante 1** — « [NOM] tombe, mais sa main trouve encore son fusil. »

| Fichier | Segment exact |
|---|---|
| `chasseur_fusil_1_apres.mp3` | tombe, mais sa main trouve encore son fusil. |

**Variante 2** — « Touché à mort, [NOM] arme une dernière fois son fusil. »

| Fichier | Segment exact |
|---|---|
| `chasseur_fusil_2_avant.mp3` | Touché à mort, |
| `chasseur_fusil_2_apres.mp3` | arme une dernière fois son fusil. |

**Variante 3** — « [NOM] s'écroule — et pointe son fusil vers la foule. »

| Fichier | Segment exact |
|---|---|
| `chasseur_fusil_3_apres.mp3` | s'écroule — et pointe son fusil vers la foule. |

<sub>Fonction source : `annoncer_bilan` (chasseur_en_attente)</sub>

## 7. Victime du tir du chasseur

Structure : `[avant] [NOM] [apres] [ROLE].`

**Variante 1** — « D'un dernier souffle, le chasseur ajuste et abat [NOM]. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_tir_1_avant.mp3` | D'un dernier souffle, le chasseur ajuste et abat |
| `mort_tir_1_apres.mp3` | Il était |

**Variante 2** — « Le coup de feu claque : [NOM] s'effondre. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_tir_2_avant.mp3` | Le coup de feu claque : |
| `mort_tir_2_apres.mp3` | s'effondre. Il était |

**Variante 3** — « Le chasseur emporte [NOM] dans sa chute. Il était [ROLE]. »

| Fichier | Segment exact |
|---|---|
| `mort_tir_3_avant.mp3` | Le chasseur emporte |
| `mort_tir_3_apres.mp3` | dans sa chute. Il était |

<sub>Fonction source : `annoncer_mort` (cause 'abattu par le chasseur')</sub>

## 8. Mort de chagrin (amoureux)

Deux pseudos dynamiques dans la même phrase : le mort `[NOM]` et son amoureux `[AMOUREUX]`.
D'où un segment `_milieu` entre les deux noms. Aucun rôle n'est révélé dans ces phrases.

**Variante 1** — « [NOM] ne survit pas à la mort de [AMOUREUX]. Le chagrin l'emporte. »
(commence par le nom : pas de segment `_avant`)

| Fichier | Segment exact |
|---|---|
| `mort_chagrin_1_milieu.mp3` | ne survit pas à la mort de |
| `mort_chagrin_1_apres.mp3` | Le chagrin l'emporte. |

**Variante 2** — « Le cœur brisé, [NOM] rejoint [AMOUREUX] dans la mort. »

| Fichier | Segment exact |
|---|---|
| `mort_chagrin_2_avant.mp3` | Le cœur brisé, |
| `mort_chagrin_2_milieu.mp3` | rejoint |
| `mort_chagrin_2_apres.mp3` | dans la mort. |

**Variante 3** — « On n'aime qu'une fois : [NOM] s'éteint auprès de [AMOUREUX]. »
(se termine sur le nom de l'amoureux : pas de segment `_apres`, la phrase finit avec le nom)

| Fichier | Segment exact |
|---|---|
| `mort_chagrin_3_avant.mp3` | On n'aime qu'une fois : |
| `mort_chagrin_3_milieu.mp3` | s'éteint auprès de |

**Secours** — si le jeu ne retrouve pas le pseudo de l'amoureux², les mots « son aimé » remplacent
`[AMOUREUX]` dans les trois variantes :

| Fichier | Segment exact |
|---|---|
| `mort_chagrin_son_aime.mp3` | son aimé |

<sub>Fonction source : `annoncer_mort` (cause 'chagrin d'amour')</sub>

## 9. Fin de partie — victoires

Phrases entièrement statiques.

**Victoire du village**

| Fichier | Phrase exacte |
|---|---|
| `victoire_village_1.mp3` | Le dernier loup est terrassé. Le village peut enfin dormir en paix. Victoire des Villageois ! |
| `victoire_village_2.mp3` | Les crocs se sont tus. Le village a triomphé. |
| `victoire_village_3.mp3` | À l'aube, plus aucun loup ne rôde. Le village l'emporte. |

**Victoire des loups**

| Fichier | Phrase exacte |
|---|---|
| `victoire_loups_1.mp3` | Les loups sont désormais les maîtres du village. Victoire des Loups-Garous ! |
| `victoire_loups_2.mp3` | Il ne reste que des crocs et du sang : les Loups-Garous ont gagné. |
| `victoire_loups_3.mp3` | Le village s'éteint dans les hurlements. Les loups triomphent. |

**Victoire des amoureux**

| Fichier | Phrase exacte |
|---|---|
| `victoire_amoureux_1.mp3` | Contre tous les camps, les deux amoureux restent seuls au monde. Victoire de l'Amour ! |
| `victoire_amoureux_2.mp3` | Le village et les loups ont péri : seuls les amoureux survivent. Victoire des Amoureux ! |
| `victoire_amoureux_3.mp3` | Leur amour a survécu à tout. Les amoureux l'emportent. |

<sub>Fonction source : `conclure`</sub>

## 10. Rôles (vocabulaire fini — `libelle_role`)

Un mot par fichier, intonation de **fin de phrase** (le jeu les colle après « Il était » : « Il était
Voyante. »)³. Le SQL dit toujours « Il **était** », même pour un rôle ou un joueur féminin — c'est voulu,
ne pas « corriger » à l'enregistrement.

| Fichier | Mot exact |
|---|---|
| `role_loup_garou.mp3` | Loup-Garou. |
| `role_villageois.mp3` | Villageois. |
| `role_voyante.mp3` | Voyante. |
| `role_sorciere.mp3` | Sorcière. |
| `role_chasseur.mp3` | Chasseur. |
| `role_cupidon.mp3` | Cupidon. |

<sub>Fonction source : `libelle_role`</sub>

---

## Récapitulatif

| Situation | Fichiers |
|---|---|
| 1. Tombée de la nuit | 3 |
| 2. Victime de la nuit (matin) | 6 |
| 3. Nuit tranquille | 3 |
| 4. Pendaison | 6 |
| 5. Vote sans mort | 3 |
| 6. Le chasseur tombe | 4 |
| 7. Victime du tir du chasseur | 6 |
| 8. Mort de chagrin | 8 |
| 9. Victoires | 9 |
| 10. Rôles | 6 |
| **Total** | **54** |

Soit 33 phrases complètes du narrateur (12 `annoncer_mort` + 9 `annoncer_bilan` + 12 `conclure`)
+ 6 libellés de rôle + 1 segment de secours « son aimé ».

## Notes de bas de page

1. **Dévoré vs empoisonné** : `annoncer_mort` ne distingue pas ces deux causes — la branche `else`
   (section 2) couvre les deux avec les mêmes 3 phrases. Il n'existe donc volontairement pas de fichiers
   `mort_empoisonne_*` distincts.
2. **« son aimé »** : filet de sécurité du SQL (`coalesce(v_amoureux, 'son aimé')`) si le couple est
   introuvable en base. En pratique une mort de chagrin implique un couple existant ; on enregistre quand
   même ce petit segment pour être complet.
3. **Point final après le rôle** : dans le SQL le rôle est suivi d'un « . » collé (`|| v_role || '.'`).
   Le point est intégré au fichier de rôle (intonation de fin de phrase), il n'y a rien d'autre à
   enregistrer après.
4. **Versions obsolètes** : les fonctions `conclure` et `tirer_chasseur` (01_chasseur.sql),
   `resoudre_phase` (01_chasseur.sql puis 03_bots_20260718.sql) et `bot_tire_chasseur`
   (03_bots_20260718.sql) sont redéfinies par 05_narrateur.sql, qui fait foi. Leurs versions antérieures
   ne contenaient **aucune** phrase de narrateur : aucune phrase n'existe uniquement dans une version
   obsolète, rien n'est perdu.
5. **Hors périmètre — messages d'erreur** : les textes des `raise exception` de toutes les migrations
   (« Ce n'est pas à toi de tirer », « Cible invalide », « Il faut au moins 6 joueurs… », « Le pseudo
   fait 3 caractères minimum », etc.) sont des erreurs renvoyées au client, jamais des messages du
   narrateur dans le chat : ils ne sont pas à enregistrer.
6. **Hors périmètre — messages des bots** : `bot_message` (04_bots_ia_20260718.sql) insère des messages
   de chat **signés par un bot** (user_id non nul), au contenu généré par l'IA : ce ne sont pas des
   messages du narrateur.
7. **`resoudre_phase`, `tirer_chasseur`, `bot_tire_chasseur`** (05_narrateur.sql) ne contiennent aucune
   chaîne propre : elles déclenchent `annoncer_mort` / `annoncer_bilan` / `conclure`, déjà couvertes
   ci-dessus. `inserer_message_systeme` est un simple canal d'écriture, sans texte propre.
8. **Rôle inconnu** : la branche `else r::text` de `libelle_role` est inatteignable — l'enum `role_type`
   ne contient que les 6 rôles listés en section 10.
