// =====================================================================
//  Edge Function « bot-ia » — Loup-Garou V2 (bots intelligents)
//
//  Fait RAISONNER, BLUFFER et CHATTER les bots via Claude Haiku.
//
//  RÈGLE D'OR : le LLM ne fait que CHOISIR parmi des coups légaux.
//  Les règles du jeu vivent en Postgres et VALIDENT tout (RPC ci-dessous).
//  Ce fichier ne contient AUCUNE logique de règles : il lit l'état,
//  demande une décision au LLM, puis appelle la RPC de validation.
//  Un coup illégal (exception RPC) est ignoré proprement : le fallback
//  heuristique V1 (côté Postgres) jouera à la place.
//
//  Secrets (jamais en dur, jamais loggés) :
//   - ANTHROPIC_API_KEY          (à définir)
//   - SUPABASE_URL               (fourni d'office aux Edge Functions)
//   - SUPABASE_SERVICE_ROLE_KEY  (fourni d'office aux Edge Functions)
//
//  Contrainte de coût du propriétaire :
//   - modèle Haiku, max_tokens PETIT (256), réponses COURTES,
//   - plafond CAP_APPELS = 60 appels LLM par partie.
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------
// Constantes (coût maîtrisé)
// ---------------------------------------------------------------------
const CAP_APPELS = 60; // plafond d'appels LLM par partie
const MODELE = "claude-haiku-4-5"; // EXACTEMENT ce modèle (pas de thinking/effort)
const MAX_TOKENS = 256; // petit : réponses obligatoirement courtes
const MAX_PHRASE = 200; // longueur max d'une phrase de chat
const VERSION_ANTHROPIC = "2023-06-01";

// ---------------------------------------------------------------------
// En-têtes CORS (invocation depuis le client / un cron)
// ---------------------------------------------------------------------
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(corps: unknown, statut = 200): Response {
  return new Response(JSON.stringify(corps), {
    status: statut,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

// ---------------------------------------------------------------------
// Quels coups sont légaux pour ce bot, selon la phase et le rôle ?
// (déduit de l'état renvoyé par etat_pour_bot — aucune règle inventée)
// ---------------------------------------------------------------------
function actionsLegales(etat: any): string[] {
  const phase = etat?.phase;
  const role = etat?.mon_role;

  if (phase === "nuit") {
    if (role === "loup_garou") return ["devorer"];
    if (role === "voyante") return ["sonder"];
    if (role === "sorciere") return ["potion_vie", "potion_mort", "passer"];
    if (role === "cupidon" && Number(etat?.cycle) === 1) return ["lier"];
    return ["passer"];
  }
  if (phase === "jour") return ["passer"]; // le jour on ne fait que discuter
  if (phase === "vote") return ["voter"];
  if (phase === "chasseur") return ["tirer"];
  return ["passer"];
}

// Canal de chat autorisé pour ce bot cette phase (sinon : pas de chat).
function canalPour(etat: any): string | null {
  const phase = etat?.phase;
  if (phase === "jour" || phase === "vote") return "village";
  if (phase === "nuit" && etat?.mon_role === "loup_garou") return "loups";
  return null;
}

// ---------------------------------------------------------------------
// Persona (system) — courte, en français, stratégique, bluff si loup.
// ---------------------------------------------------------------------
function personaSystem(etat: any): string {
  const role = etat?.mon_role ?? "villageois";
  const camp = etat?.mon_camp ?? "village";
  const estLoup = camp === "loups";
  return [
    "Tu es un joueur de Loup-Garou dans une partie en ligne, en français.",
    `Ton rôle : ${role}. Ton camp : ${camp}.`,
    "Joue de façon stratégique pour faire gagner ton camp.",
    estLoup
      ? "Tu es dans le camp des loups : BLUFFE, brouille les pistes, ne te trahis pas."
      : "Tu es dans le camp du village : cherche les loups, méfie-toi des accusations trop faciles.",
    "Choisis UNIQUEMENT parmi les actions légales proposées, et cible par user_id parmi les vivants.",
    "Reste très bref. Réponds en français. La phrase de chat est optionnelle et doit faire au plus 200 caractères.",
  ].join(" ");
}

// ---------------------------------------------------------------------
// Schéma JSON de sortie (structured output) — objet compact.
// ---------------------------------------------------------------------
function schemaSortie(legales: string[]) {
  const nullableString = {
    anyOf: [{ type: "string" }, { type: "null" }],
  };
  return {
    type: "object",
    additionalProperties: false,
    properties: {
      action: {
        type: "object",
        additionalProperties: false,
        properties: {
          type: { type: "string", enum: legales },
          cible: nullableString, // user_id de la cible principale (ou null)
          cible2: nullableString, // user_id de la 2e cible (cupidon 'lier'), sinon null
        },
        required: ["type", "cible", "cible2"],
      },
      phrase: { type: "string" }, // phrase de chat très courte (peut être "")
    },
    required: ["action", "phrase"],
  };
}

// ---------------------------------------------------------------------
// Appel Haiku (HTTP brut) → décision structurée. Parse défensif.
// Renvoie null si quoi que ce soit tourne mal (le fallback jouera).
// ---------------------------------------------------------------------
async function demanderDecision(
  cleApi: string,
  etat: any,
  legales: string[],
): Promise<{ action: any; phrase?: string } | null> {
  const corps = {
    model: MODELE,
    max_tokens: MAX_TOKENS,
    system: personaSystem(etat),
    messages: [
      {
        role: "user",
        content: [
          {
            type: "text",
            text:
              "Voici ce que tu sais (ne te fie qu'à ça) :\n" +
              JSON.stringify(etat) +
              "\n\nActions légales pour cette phase : " +
              JSON.stringify(legales) +
              ".\nRéponds par l'objet JSON demandé : action.type (parmi les légales)," +
              " action.cible et action.cible2 (user_id parmi les vivants, ou null)," +
              " et une phrase de chat courte (ou une chaîne vide).",
          },
        ],
      },
    ],
    output_config: {
      format: {
        type: "json_schema",
        schema: schemaSortie(legales),
      },
    },
  };

  let reponse: Response;
  try {
    reponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": cleApi,
        "anthropic-version": VERSION_ANTHROPIC,
        "content-type": "application/json",
      },
      body: JSON.stringify(corps),
    });
  } catch (_e) {
    console.error("bot-ia: échec réseau vers l'API Claude");
    return null;
  }

  if (!reponse.ok) {
    // Ne jamais logger la clé ni le corps complet.
    console.error("bot-ia: réponse API non-OK", reponse.status);
    return null;
  }

  let data: any;
  try {
    data = await reponse.json();
  } catch (_e) {
    console.error("bot-ia: réponse API illisible");
    return null;
  }

  // Concatène les blocs texte puis parse le JSON.
  let texte = "";
  for (const bloc of data?.content ?? []) {
    if (bloc?.type === "text" && typeof bloc.text === "string") {
      texte += bloc.text;
    }
  }
  if (!texte) return null;

  try {
    const obj = JSON.parse(texte);
    if (!obj || typeof obj !== "object" || !obj.action) return null;
    return obj;
  } catch (_e) {
    console.error("bot-ia: JSON de décision invalide");
    return null;
  }
}

// ---------------------------------------------------------------------
// Applique la décision via la RPC de validation adéquate.
// Toute exception (coup illégal) est ignorée : le fallback jouera.
// ---------------------------------------------------------------------
async function appliquerDecision(
  supabase: any,
  partieId: string,
  botId: string,
  decision: { action: any; phrase?: string },
  etat: any,
): Promise<boolean> {
  const type = decision?.action?.type as string | undefined;
  const cible = decision?.action?.cible ?? null;
  const cible2 = decision?.action?.cible2 ?? null;
  if (!type) return false;

  const actionsNuit = ["devorer", "sonder", "potion_vie", "potion_mort", "lier"];

  let joue = false;

  try {
    if (actionsNuit.includes(type)) {
      const { error } = await supabase.rpc("bot_agir_nuit", {
        p_partie: partieId,
        p_bot: botId,
        p_action: type,
        p_cible: cible,
        p_cible2: cible2,
      });
      if (!error) joue = true;
    } else if (type === "voter") {
      const { error } = await supabase.rpc("bot_voter", {
        p_partie: partieId,
        p_bot: botId,
        p_cible: cible,
      });
      if (!error) joue = true;
    } else if (type === "tirer") {
      // Hypothèse : le tir du chasseur passe par bot_agir_nuit('tirer').
      // Si cette RPC rejette 'tirer', le fallback Postgres (bot_tire_chasseur
      // dans resoudre_phase) s'en charge — donc rien ne casse.
      const { error } = await supabase.rpc("bot_agir_nuit", {
        p_partie: partieId,
        p_bot: botId,
        p_action: "tirer",
        p_cible: cible,
        p_cible2: null,
      });
      if (!error) joue = true;
    }
    // 'passer' : aucune action de jeu, seulement (peut-être) du chat.
  } catch (_e) {
    // Coup illégal / exception RPC : on ignore proprement.
  }

  // Chat éventuel, sur le bon canal, si une phrase courte est fournie.
  const canal = canalPour(etat);
  const phrase = (decision?.phrase ?? "").trim();
  if (canal && phrase) {
    try {
      await supabase.rpc("bot_message", {
        p_partie: partieId,
        p_bot: botId,
        p_canal: canal,
        p_contenu: phrase.slice(0, MAX_PHRASE),
      });
    } catch (_e) {
      // Le chat n'est jamais bloquant.
    }
  }

  return joue;
}

// ---------------------------------------------------------------------
// Handler HTTP principal (POST { partie_id })
// ---------------------------------------------------------------------
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }
  if (req.method !== "POST") {
    return json({ erreur: "méthode non autorisée" }, 405);
  }

  // Corps
  let partieId: string | undefined;
  try {
    const corps = await req.json();
    partieId = corps?.partie_id;
  } catch (_e) {
    return json({ erreur: "corps JSON invalide" }, 400);
  }
  if (!partieId) {
    return json({ erreur: "partie_id manquant" }, 400);
  }

  // Secrets
  const cleApi = Deno.env.get("ANTHROPIC_API_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!cleApi || !url || !serviceKey) {
    console.error("bot-ia: secret(s) manquant(s)");
    return json({ erreur: "configuration incomplète" }, 500);
  }

  const supabase = createClient(url, serviceKey);

  let joues = 0;
  let appels = 0;

  try {
    // Bots à faire jouer pour la phase courante.
    const { data: bots, error: errBots } = await supabase.rpc(
      "bots_a_faire_jouer",
      { p_partie: partieId },
    );
    if (errBots) {
      console.error("bot-ia: bots_a_faire_jouer a échoué");
      return json({ erreur: "état indisponible" }, 500);
    }

    const liste = Array.isArray(bots) ? bots : [];

    for (const bot of liste) {
      const botId = bot?.user_id;
      if (!botId) continue;

      // Try/catch par bot : un bot planté n'arrête pas les autres.
      try {
        // État restreint à ce que ce bot a le droit de savoir.
        const { data: etat, error: errEtat } = await supabase.rpc(
          "etat_pour_bot",
          { p_partie: partieId, p_bot: botId },
        );
        if (errEtat || !etat) continue;

        const legales = actionsLegales(etat);
        // Rien de décidable par le LLM : on laisse le fallback jouer.
        if (legales.length === 0) continue;

        // Plafond de coût : incrémente AVANT chaque appel LLM.
        const { data: nbAppels, error: errCpt } = await supabase.rpc(
          "incrementer_appels_ia",
          { p_partie: partieId },
        );
        if (errCpt) {
          // Impossible de comptabiliser : par prudence, on n'appelle pas le LLM.
          continue;
        }
        appels = typeof nbAppels === "number" ? nbAppels : appels + 1;

        // Dépassement du plafond : on ARRÊTE d'appeler le LLM pour cette partie.
        if (appels > CAP_APPELS) {
          break;
        }

        const decision = await demanderDecision(cleApi, etat, legales);
        if (!decision) continue; // le fallback jouera

        const aJoue = await appliquerDecision(
          supabase,
          partieId,
          botId,
          decision,
          etat,
        );
        if (aJoue) joues += 1;
      } catch (_e) {
        console.error("bot-ia: erreur sur un bot (ignorée)");
        continue;
      }
    }
  } catch (_e) {
    console.error("bot-ia: erreur inattendue");
    return json({ erreur: "erreur interne", joues, appels }, 500);
  }

  return json({ joues, appels });
});
