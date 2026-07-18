#!/usr/bin/env node
// =====================================================================
//  Test de fumée — étanchéité des rôles (le seul test qui compte)
//
//  Crée 6 comptes de test, ouvre une partie, les fait tous rejoindre,
//  la lance, puis vérifie que PERSONNE ne voit un rôle qu'il ne devrait
//  pas voir.
//
//  Rappel de la règle RLS (policy "roles secrets") :
//    tu vois ton propre rôle ; un loup voit aussi toute sa meute ;
//    tout est révélé en fin de partie.
//  Donc la propriété testée n'est PAS « exactement 1 rôle par joueur »
//  (les loups en voient plusieurs, légitimement) mais :
//    - un non-loup ne voit QUE son propre rôle ;
//    - un loup ne voit QUE lui-même + d'autres loups.
//  Toute visibilité en dehors de ça est une FUITE critique.
//
//  Usage : node tests/fumee.mjs
// =====================================================================

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createClient } from '@supabase/supabase-js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// --- On lit les clés dans app.html (source unique de vérité) ----------
const appHtml = readFileSync(join(__dirname, '..', 'app.html'), 'utf8');
const url = appHtml.match(/const SUPABASE_URL\s*=\s*'([^']+)'/)?.[1];
const anon = appHtml.match(/const SUPABASE_ANON\s*=\s*'([^']+)'/)?.[1];
if (!url || !anon || /TON-PROJET|TA_CLE/.test(url + anon)) {
  console.error('❌ Clés Supabase absentes ou non renseignées dans app.html.');
  process.exit(1);
}

const NB = 6;
const stamp = process.hrtime.bigint().toString(36);
const mkClient = () => createClient(url, anon, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const fail = (msg) => { console.error('\n❌ ' + msg); process.exit(1); };
const ok   = (msg) => console.log('✅ ' + msg);

console.log(`— Test de fumée (${NB} comptes) sur ${url} —\n`);

// --- 1. Création des 6 comptes ---------------------------------------
const users = [];
for (let i = 0; i < NB; i++) {
  const client = mkClient();
  const email = `fumee_${stamp}_${i}@loupgarou.test`;
  const password = `Fumee!${stamp}${i}aA`;
  const pseudo = `Fumee_${stamp.slice(-4)}_${i}`;
  const { data, error } = await client.auth.signUp({
    email, password, options: { data: { pseudo } },
  });
  if (error) fail(`Inscription du compte ${i} refusée : ${error.message}`);
  if (!data.session) {
    fail(
      `Le compte ${i} a été créé mais SANS session active.\n` +
      `   → La confirmation d'e-mail est probablement ACTIVÉE sur le projet.\n` +
      `   Pour ce test automatique, désactive « Confirm email » dans\n` +
      `   Supabase → Authentication → Sign In / Providers → Email,\n` +
      `   ou dis-le moi et je te guide.`
    );
  }
  users.push({ i, client, id: data.user.id, pseudo });
  process.stdout.write(`  compte ${i} créé (${data.user.id.slice(0, 8)}…)\n`);
}
ok(`${NB} comptes créés avec session active`);

// --- 2. Ouverture de la partie par l'hôte (compte 0) ------------------
const host = users[0];
const { data: partieRaw, error: eCreer } = await host.client.rpc('creer_partie', {
  p_max: 12, p_publique: true,
});
if (eCreer) fail(`creer_partie a échoué : ${eCreer.message}`);
const partie = Array.isArray(partieRaw) ? partieRaw[0] : partieRaw;
const partieId = partie.id;
const code = partie.code;
ok(`partie ouverte par le compte 0 — code ${code}`);

// --- 3. Les 5 autres rejoignent --------------------------------------
for (const u of users.slice(1)) {
  const { error } = await u.client.rpc('rejoindre_partie', { p_code: code });
  if (error) fail(`Le compte ${u.i} n'a pas pu rejoindre : ${error.message}`);
}
ok(`les ${NB - 1} autres comptes ont rejoint la partie`);

// --- 4. Lancement (distribution des rôles côté serveur) ---------------
const { error: eDemarrer } = await host.client.rpc('demarrer_partie', { p_partie: partieId });
if (eDemarrer) fail(`demarrer_partie a échoué : ${eDemarrer.message}`);
ok('partie lancée — rôles distribués par la fonction serveur');

// --- 5. Ce que chaque compte peut LIRE dans roles_joueurs -------------
const vues = new Map(); // viewerId -> [{user_id, role, camp}]
for (const u of users) {
  const { data, error } = await u.client
    .from('roles_joueurs')
    .select('user_id, role, camp')
    .eq('partie_id', partieId);
  if (error) fail(`Lecture des rôles impossible pour le compte ${u.i} : ${error.message}`);
  vues.set(u.id, data);
}

// Vérité terrain : chaque joueur voit au moins son propre rôle.
const verite = new Map(); // user_id -> {role, camp}
for (const u of users) {
  const propre = (vues.get(u.id) || []).find((r) => r.user_id === u.id);
  if (!propre) fail(`Le compte ${u.i} ne voit MÊME PAS son propre rôle.`);
  verite.set(u.id, { role: propre.role, camp: propre.camp });
}

// --- 6. Analyse des fuites -------------------------------------------
const loups = [...verite.entries()].filter(([, v]) => v.camp === 'loups').map(([id]) => id);
const idToUser = new Map(users.map((u) => [u.id, u]));
const fuites = [];

for (const u of users) {
  const vuePropre = verite.get(u.id);
  const suisLoup = vuePropre.camp === 'loups';
  for (const r of vues.get(u.id) || []) {
    if (r.user_id === u.id) continue;               // son propre rôle : normal
    const autorise = suisLoup && r.camp === 'loups'; // meute des loups : normal
    if (!autorise) {
      const cible = idToUser.get(r.user_id);
      fuites.push(
        `Le compte ${u.i} (${vuePropre.role}/${vuePropre.camp}) VOIT le rôle du compte ` +
        `${cible ? cible.i : '?'} → ${r.role}/${r.camp}`
      );
    }
  }
}

console.log(`\n  Composition : ${loups.length} loup(s), ${NB - loups.length} autre(s).`);
for (const u of users) {
  const v = verite.get(u.id);
  const n = (vues.get(u.id) || []).length;
  console.log(`   compte ${u.i} : ${v.role}/${v.camp} — voit ${n} rôle(s)`);
}

if (fuites.length > 0) {
  console.error('\n🚨 FUITE DE RÔLES DÉTECTÉE — ARRÊT IMMÉDIAT 🚨');
  fuites.forEach((f) => console.error('   • ' + f));
  process.exit(2);
}

// Contrôle de cohérence : un loup doit bien voir toute la meute (sinon RLS trop stricte)
for (const id of loups) {
  const vus = new Set((vues.get(id) || []).filter((r) => r.camp === 'loups').map((r) => r.user_id));
  for (const autre of loups) {
    if (!vus.has(autre)) {
      console.warn(`⚠️  Un loup ne voit pas un membre de sa meute (RLS trop stricte, non bloquant).`);
    }
  }
}

console.log('\n✅✅ ÉTANCHÉITÉ DES RÔLES CONFIRMÉE — aucun compte ne voit un rôle interdit.');
process.exit(0);
