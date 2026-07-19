# Pack voix du narrateur — provisoire

## Ce que c'est
44 fichiers mp3 : les 22 annonces du narrateur en version générique
(sans nom de joueur — le nom reste à l'écran), en deux voix de synthèse
libres de droits (moteur Piper, licence MIT, voix siwis/gilles CC) :

- `conteuse/` — voix féminine, la meilleure qualité. **Recommandée.**
- `conteur/`  — voix masculine, qualité moindre (modèle 16 kHz).

Défaut connu : les voyelles nasales (on, an, in) sonnent parfois un peu
étranges — limite des modèles. C'est un pack PROVISOIRE : le but est que
le jeu parle dès aujourd'hui et que la plomberie soit testée.

## Installation
1. Choisis un dossier de voix, copie SON CONTENU + manifest.json dans
   `assets/voix/` du dépôt.
2. Commit, push — Netlify redéploie.
3. Donne à Claude Code le prompt d'INTEGRATION.md pour brancher la lecture.

## Remplacer par ta vraie voix (le vrai objectif)
Enregistre chaque phrase (elles sont dans manifest.json et dans
A_ENREGISTRER.md), exporte en mp3 mono avec EXACTEMENT les mêmes noms de
fichiers, remplace dans assets/voix/, commit. Rien d'autre à changer.

Astuce Mac : le script `regenerer_voix_mac.sh` fournit une alternative
immédiate avec la voix système française de macOS (souvent meilleure que
ce pack) — lance-le sur ton Mac, il produit les mêmes fichiers.
