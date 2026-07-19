# Sons — crédits & licences

## Musiques d'ambiance (fichiers réels, CC0)

Deux boucles musicales déposées dans `assets/sons/` le 2026-07-19, en attente
d'intégration dans le module `Ambiance` :

| Fichier | Usage | Titre original | Auteur | Source | Licence | Durée / poids |
|---|---|---|---|---|---|---|
| `musique_nuit.mp3` | Nappe musicale de nuit (sombre, drone) | « Dark Ambient Loop » | goulven | [freesound.org/people/goulven/sounds/371277](https://freesound.org/people/goulven/sounds/371277/) | **CC0 1.0** (Creative Commons Zero — domaine public, aucune attribution requise) | 30,9 s / 680 Ko |
| `musique_jour.mp3` | Nappe musicale de jour (claire, luth médiéval) | « Medieval Lute Chords » | f-r-a-g-i-l-e | [freesound.org/people/f-r-a-g-i-l-e/sounds/506266](https://freesound.org/people/f-r-a-g-i-l-e/sounds/506266/) | **CC0 1.0** (Creative Commons Zero — domaine public, aucune attribution requise) | 14,5 s / 326 Ko |

Note : les mp3 sont les rendus « HQ preview » (~180 kb/s VBR) fournis par le
CDN de Freesound pour ces sons ; la licence CC0 du son original s'applique à
l'identique. Attribution fournie ici par courtoisie, non obligatoire en CC0.

## Effets sonores synthétisés

Tous les autres sons du jeu sont **synthétisés en direct dans le navigateur** via l'API
Web Audio (voir le module `Ambiance` dans `app.html`). **Aucun fichier audio
externe n'est utilisé** pour les effets, donc :

- aucun téléchargement, aucun poids réseau ;
- **aucune question de copyright** — rien n'est emprunté à une banque de sons,
  un film ou une vidéo.

## Sons générés

| Évènement | Synthèse |
|---|---|
| Nappe nuit | bruit brun filtré passe-bas + hibou / hurlement lointain espacés |
| Nappe jour | bruit filtré plus clair + gazouillis d'oiseaux espacés |
| Tombée de la nuit | cloche (2 coups) |
| Lever du jour | coq (motif de 4 notes) |
| Vote posé | claquement de bois sec |
| Victime dévorée | grognement grave |
| Lynchage | grondement de foule qui monte puis retombe |
| Voyante sonde | tintement cristallin |
| Sorcière (fiole) | bouchon + liquide versé |
| Chasseur tire | détonation sourde |
| Victoire village | cloches en volée |
| Victoire loups | hurlement de meute |
| Victoire amoureux | note tenue (harpe) |

## Remplacer par de vrais enregistrements (optionnel, plus tard)

Si tu veux un rendu plus riche, dépose des fichiers libres de droits ici
(`assets/sons/`) et branche-les dans le module `Ambiance` à la place de la
synthèse. Sources conseillées, licence à vérifier au cas par cas :
Freesound (filtrer CC0), Pixabay Sound Effects, Uppbeat, Zapsplat.
Ne jamais prendre un son sur YouTube ou un site de sons de films.
Formats : nappes en `.webm`/`.mp3` bouclés (30–60 s, < 300 Ko) ;
ponctuations en `.mp3` courts (< 30 Ko).
