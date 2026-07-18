# Edge Function `bot-ia` — bots intelligents (V2)

Cette fonction fait **raisonner, bluffer et chatter** les bots du jeu de
Loup-Garou grâce à **Claude Haiku**. Elle se pose par-dessus la plomberie V1
(migration `03_bots_20260718.sql`) sans jamais dupliquer les règles.

## À quoi elle sert

Quand c'est aux bots de jouer (nuit, vote, jour, chasseur), on l'appelle en
POST avec `{ "partie_id": "<uuid>" }`. Pour chaque bot à faire jouer, elle :

1. lit **uniquement** ce que ce bot a le droit de savoir (RPC `etat_pour_bot`) ;
2. demande à Claude Haiku de **choisir un coup parmi les coups légaux** (nuit
   selon le rôle, vote = une cible, chasseur = une cible), plus une éventuelle
   phrase de chat très courte ;
3. **applique** ce choix via la RPC de validation Postgres correspondante
   (`bot_agir_nuit` / `bot_voter`) et, si une phrase est fournie, l'envoie sur
   le bon canal (`bot_message`).

**Règle d'or :** le LLM ne fait que *choisir*. Les règles vivent en Postgres
et **valident tout**. Un coup illégal (exception RPC) est ignoré proprement :
le **fallback heuristique V1** (côté Postgres) joue alors à la place. Aucune
logique de règles n'est écrite dans cette fonction.

## Coût maîtrisé

- Modèle : `claude-haiku-4-5` (pas de `thinking` ni `effort`).
- `max_tokens` **petit (256)** + sortie structurée JSON → réponses courtes.
- Plafond : **`CAP_APPELS = 60`** appels LLM par partie. Au-delà, la fonction
  **arrête d'appeler le LLM** pour cette partie (les bots sont alors joués par
  le fallback V1). Le décompte se fait via la RPC `incrementer_appels_ia`.

## Les 3 secrets requis

| Secret | À définir soi-même ? |
| --- | --- |
| `ANTHROPIC_API_KEY` | **Oui** — à ajouter dans les secrets de la fonction. Jamais en dur, jamais loggée. |
| `SUPABASE_URL` | Non — fourni automatiquement aux Edge Functions. |
| `SUPABASE_SERVICE_ROLE_KEY` | Non — fourni automatiquement aux Edge Functions. |

Définir la clé Anthropic (une seule fois) :

```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```

(ou via le dashboard Supabase → Edge Functions → Secrets)

## Déploiement

Deux options, au choix :

- **Dashboard Supabase** → *Edge Functions* → créer/mettre à jour la fonction
  `bot-ia` en collant le contenu de `index.ts`, puis renseigner le secret
  `ANTHROPIC_API_KEY`.
- **CLI Supabase** :

  ```bash
  supabase functions deploy bot-ia
  ```

## Appel

```bash
curl -X POST "https://<projet>.supabase.co/functions/v1/bot-ia" \
  -H "Authorization: Bearer <clé>" \
  -H "content-type: application/json" \
  -d '{ "partie_id": "<uuid>" }'
```

Réponse : `{ "joues": N, "appels": M }` (nombre de coups appliqués et
d'appels LLM effectués). Les erreurs par bot n'interrompent jamais les autres.

## Contrat des RPC Postgres attendues

Écrites en parallèle côté SQL. Cette fonction suppose ces signatures :

- `bots_a_faire_jouer(p_partie)` → liste de `{ user_id, role }`
- `etat_pour_bot(p_partie, p_bot)` → `jsonb` (mon_role, mon_camp, vivants[],
  ma_meute[], phase, cycle, votes[], chat[], mes_actions[])
- `incrementer_appels_ia(p_partie)` → `int`
- `bot_agir_nuit(p_partie, p_bot, p_action, p_cible, p_cible2)` → `'ok'` ou
  exception (`p_action` ∈ `devorer|sonder|potion_vie|potion_mort|lier`)
- `bot_voter(p_partie, p_bot, p_cible)` → `'ok'` ou exception
- `bot_message(p_partie, p_bot, p_canal, p_contenu)` → `'ok'` ou exception
  (`p_canal` ∈ `village|loups|morts`)

**Note sur le chasseur :** le contrat ne fournit pas de RPC dédiée au tir du
chasseur. La fonction tente `bot_agir_nuit(..., 'tirer', ...)` ; si cette RPC
rejette `'tirer'`, le fallback Postgres (`bot_tire_chasseur` dans
`resoudre_phase`) s'en charge, donc rien ne casse.
