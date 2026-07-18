# Sons — crédits & licences

Tous les sons du jeu sont **synthétisés en direct dans le navigateur** via l'API
Web Audio (voir le module `Ambiance` dans `app.html`). **Aucun fichier audio
externe n'est utilisé**, donc :

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
