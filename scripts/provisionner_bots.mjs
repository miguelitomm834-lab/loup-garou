#!/usr/bin/env node
// =====================================================================
//  Provisionnement des comptes bots (à lancer UNE fois)
//
//  Crée N comptes techniques bot_01..bot_NN @loupgarou.test dans
//  auth.users (via signUp — la confirmation d'e-mail est désactivée, donc
//  aucun mail n'est envoyé). Le profil est créé automatiquement par le
//  trigger. Ensuite, exécute `select marquer_bots();` dans Supabase pour
//  poser profils.est_bot = true sur ces comptes.
//
//  Idempotent : un bot déjà existant est simplement ignoré.
//  Usage : node scripts/provisionner_bots.mjs [N]   (défaut 12)
// =====================================================================

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createClient } from '@supabase/supabase-js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(__dirname, '..', 'app.html'), 'utf8');
const url = html.match(/const SUPABASE_URL\s*=\s*'([^']+)'/)?.[1];
const anon = html.match(/const SUPABASE_ANON\s*=\s*'([^']+)'/)?.[1];
if (!url || !anon) { console.error('Clés Supabase introuvables dans app.html'); process.exit(1); }

const N = Math.min(Math.max(parseInt(process.argv[2] || '12', 10), 1), 24);
const sb = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });

console.log(`Provisionnement de ${N} bots sur ${url}\n`);
let crees = 0, deja = 0;
for (let i = 1; i <= N; i++) {
  const nn = String(i).padStart(2, '0');
  const email = `bot_${nn}@loupgarou.test`;
  const password = `BotLoup!${nn}_kbyyczp`;      // fixe : re-run idempotent
  const pseudo = `Bot ${nn}`;
  const { data, error } = await sb.auth.signUp({ email, password, options: { data: { pseudo } } });
  if (error) {
    if (/already registered|already been registered|User already/i.test(error.message)) {
      deja++; console.log(`  ${email.padEnd(28)} déjà présent`);
    } else {
      console.log(`  ${email.padEnd(28)} ERREUR: ${error.message}`);
    }
  } else {
    crees++; console.log(`  ${email.padEnd(28)} créé (${data.user?.id?.slice(0, 8)}…)`);
  }
}
console.log(`\n${crees} créé(s), ${deja} déjà présent(s).`);
console.log('➡️  Étape suivante : exécuter `select marquer_bots();` dans Supabase (SQL Editor).');
