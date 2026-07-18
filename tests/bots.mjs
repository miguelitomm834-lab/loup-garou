#!/usr/bin/env node
// =====================================================================
//  Test bots V1 — une partie complète 2 humains + 4 bots
//
//  Vérifie :
//   1. remplir_avec_bots ajoute bien 4 bots (6 joueurs, dont 4 est_bot).
//   2. ÉTANCHÉITÉ : après le lancement, chaque humain ne voit que les rôles
//      autorisés (le sien ; + la meute s'il est loup). Aucune fuite.
//   3. La partie va jusqu'à 'terminee' avec un vainqueur, sans blocage
//      (les bots jouent DANS resoudre_phase, jamais avant les humains).
//
//  Les bots jouent tout seuls quand l'hôte fait avancer la phase
//  (resoudre_phase), comme en vrai quand le chrono de l'hôte tombe à zéro.
//  Usage : node tests/bots.mjs
// =====================================================================

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createClient } from '@supabase/supabase-js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(__dirname, '..', 'app.html'), 'utf8');
const url = html.match(/const SUPABASE_URL\s*=\s*'([^']+)'/)?.[1];
const anon = html.match(/const SUPABASE_ANON\s*=\s*'([^']+)'/)?.[1];
if (!url || !anon) { console.error('❌ Clés Supabase introuvables dans app.html'); process.exit(1); }

const stamp = process.hrtime.bigint().toString(36);
const mk = () => createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
const fail = (m) => { console.error('\n❌ ' + m); process.exit(1); };
const ok = (m) => console.log('✅ ' + m);
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

console.log(`— Test bots V1 (2 humains + 4 bots) sur ${url} —\n`);

// --- 2 comptes humains ------------------------------------------------
const humains = [];
for (let i = 0; i < 2; i++) {
  const client = mk();
  const { data, error } = await client.auth.signUp({
    email: `botstest_${stamp}_${i}@loupgarou.test`,
    password: `BotsTest!${stamp}${i}aA`,
    options: { data: { pseudo: `Humain_${stamp.slice(-4)}_${i}` } },
  });
  if (error) fail(`Inscription humain ${i} : ${error.message}`);
  if (!data.session) fail(`Humain ${i} sans session (confirmation e-mail réactivée ?)`);
  humains.push({ i, client, id: data.user.id });
}
ok('2 comptes humains créés');

const hote = humains[0];

// --- Ouverture + join du 2e humain -----------------------------------
const { data: pRaw, error: eC } = await hote.client.rpc('creer_partie', { p_max: 12, p_publique: true });
if (eC) fail(`creer_partie : ${eC.message}`);
const partie = Array.isArray(pRaw) ? pRaw[0] : pRaw;
const partieId = partie.id;
const { error: eJ } = await humains[1].client.rpc('rejoindre_partie', { p_code: partie.code });
if (eJ) fail(`rejoindre_partie : ${eJ.message}`);
ok(`partie ouverte (code ${partie.code}), 2 humains dedans`);

// --- Compléter avec 4 bots -------------------------------------------
const { data: nbAjoutes, error: eB } = await hote.client.rpc('remplir_avec_bots', { p_partie: partieId, p_nb: 4 });
if (eB) fail(`remplir_avec_bots : ${eB.message}`);
if (nbAjoutes !== 4) fail(`remplir_avec_bots a ajouté ${nbAjoutes} bots au lieu de 4.`);

const { data: joueurs } = await hote.client
  .from('joueurs_partie').select('user_id, profils(est_bot)').eq('partie_id', partieId);
const nbBots = joueurs.filter((j) => j.profils?.est_bot).length;
if (joueurs.length !== 6) fail(`${joueurs.length} joueurs au lieu de 6.`);
if (nbBots !== 4) fail(`${nbBots} bots visibles au lieu de 4.`);
ok(`4 bots ajoutés → 6 joueurs (dont 4 🤖)`);

// --- Lancement --------------------------------------------------------
const { error: eD } = await hote.client.rpc('demarrer_partie', { p_partie: partieId });
if (eD) fail(`demarrer_partie : ${eD.message}`);
ok('partie lancée');

// --- ÉTANCHÉITÉ (juste après lancement, avant toute révélation) ------
for (const u of humains) {
  const { data: vues, error } = await u.client
    .from('roles_joueurs').select('user_id, role, camp').eq('partie_id', partieId);
  if (error) fail(`lecture rôles humain ${u.i} : ${error.message}`);
  const propre = vues.find((r) => r.user_id === u.id);
  if (!propre) fail(`L'humain ${u.i} ne voit pas son propre rôle.`);
  const suisLoup = propre.camp === 'loups';
  for (const r of vues) {
    if (r.user_id === u.id) continue;
    const autorise = suisLoup && r.camp === 'loups';
    if (!autorise) fail(`FUITE : l'humain ${u.i} (${propre.role}) voit ${r.role}/${r.camp} d'un autre joueur !`);
  }
  console.log(`   humain ${u.i} : ${propre.role}/${propre.camp} — voit ${vues.length} rôle(s), rien d'interdit`);
}
ok('étanchéité des rôles OK (bots inclus)');

// --- Simulation jusqu'à la fin ---------------------------------------
const vivants = async (client) => (await client
  .from('joueurs_partie').select('user_id').eq('partie_id', partieId).eq('vivant', true)).data.map((x) => x.user_id);
const estVivant = async (u) => !!(await u.client
  .from('joueurs_partie').select('vivant').eq('partie_id', partieId).eq('user_id', u.id).maybeSingle()).data?.vivant;

let garde = 0, statutFinal = null, vainqueur = null;
while (garde++ < 60) {
  const { data: p } = await hote.client.from('parties').select('*').eq('id', partieId).single();
  if (p.statut === 'terminee') { statutFinal = 'terminee'; vainqueur = p.vainqueur; break; }

  // Cas chasseur humain : il doit tirer lui-même (sinon resoudre attend le chrono)
  if (p.statut === 'chasseur' && p.chasseur_en_attente) {
    const h = humains.find((u) => u.id === p.chasseur_en_attente);
    if (h) {
      const cibles = (await vivants(h.client)).filter((id) => id !== h.id);
      if (cibles.length) { try { await h.client.rpc('tirer_chasseur', { p_partie: partieId, p_cible: pick(cibles) }); } catch (_) {} }
      continue; // tirer_chasseur enchaîne déjà la suite ; on ne rappelle pas resoudre_phase
    }
    // sinon (bot chasseur) : resoudre_phase s'en occupe plus bas
  }

  // Les humains agissent AVANT la résolution
  for (const u of humains) {
    if (!(await estVivant(u))) continue;
    if (p.statut === 'nuit') {
      const mine = (await u.client.from('roles_joueurs').select('role').eq('partie_id', partieId).eq('user_id', u.id).maybeSingle()).data;
      const autres = (await vivants(u.client)).filter((id) => id !== u.id);
      if (!autres.length) continue;
      try {
        if (mine?.role === 'loup_garou') await u.client.rpc('agir_nuit', { p_partie: partieId, p_action: 'devorer', p_cible: pick(autres) });
        else if (mine?.role === 'voyante') await u.client.rpc('agir_nuit', { p_partie: partieId, p_action: 'sonder', p_cible: pick(autres) });
        else if (mine?.role === 'cupidon' && p.cycle === 1 && autres.length >= 2)
          await u.client.rpc('agir_nuit', { p_partie: partieId, p_action: 'lier', p_cible: autres[0], p_cible2: autres[1] });
      } catch (_) {}
    } else if (p.statut === 'vote') {
      const autres = (await vivants(u.client)).filter((id) => id !== u.id);
      if (autres.length) { try { await u.client.rpc('voter', { p_partie: partieId, p_cible: pick(autres) }); } catch (_) {} }
    }
  }

  // L'hôte fait avancer la phase (imite le chrono → les bots jouent dans resoudre_phase)
  const { error } = await hote.client.rpc('resoudre_phase', { p_partie: partieId });
  if (error) fail(`resoudre_phase (tour ${garde}, statut ${p.statut}) : ${error.message}`);
}

if (statutFinal !== 'terminee') fail(`La partie n'a pas abouti en ${garde} tours (blocage ?).`);
if (!vainqueur) fail('Partie terminée mais sans vainqueur.');
ok(`partie menée à terme en ${garde} tours — vainqueur : ${vainqueur}`);

console.log('\n✅✅ V1 BOTS OK — partie complète avec bots, aucune fuite de rôle, aucun blocage.');
process.exit(0);
