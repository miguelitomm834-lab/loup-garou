-- =====================================================================
--  Tests — Skins de statue (migration 09_skins)
--
--  Prérequis (même harnais que tests_complets.sql) : un PostgreSQL local
--  chargé dans l'ordre
--     psql -d lg -f tests/00_stub_supabase.sql
--     psql -d lg -f supabase/schema_complet.sql
--     psql -d lg -f supabase/migrations/08_stats_20260719.sql   (profil_stats)
--     psql -d lg -f supabase/migrations/09_skins_20260719.sql
--     psql -d lg -f tests/skins.sql
--
--  Couvre : choix libre du jour un, refus d'un skin non mérité, déblocage
--  après injection de stats, valeur inconnue -> false, anti-fuite en
--  pleine partie, et le garde-fou RLS sur les colonnes skin_*.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
\set QUIET on

truncate parties, profils, auth.users cascade;

insert into auth.users (email, raw_user_meta_data)
values ('sculpteur@test.fr', jsonb_build_object('pseudo', 'Sculpteur'));

create or replace function _uid(p text) returns uuid language sql as
  $$ select id from auth.users where email = p $$;
create or replace function _incarner(p text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', _uid(p)::text, true)::void $$;

do $$
declare
  v_u      uuid;
  v_partie uuid;
  v_ok int := 0; v_ko int := 0;
begin
  v_u := _uid('sculpteur@test.fr');
  perform _incarner('sculpteur@test.fr');

  -- ═══════════ 1. Profil neuf : choix libre (rune + teinte) ═══════════
  begin
    perform choisir_skin('granit', 'rune_s', 'aucune', 'fissure', 'ambre');
    if (select skin_gravure = 'rune_s' and skin_teinte = 'ambre'
          from profils where id = v_u) then
      v_ok := v_ok + 1; raise notice '  OK   1. Profil neuf : rune + teinte libres acceptees';
    else
      v_ko := v_ko + 1; raise notice '  KO   1. Skin non enregistre';
    end if;
  exception when others then
    v_ko := v_ko + 1; raise notice '  KO   1. Choix libre refuse a tort : %', sqlerrm;
  end;

  -- ═══════════ 2. Obsidienne sans stats : REFUS ═══════════
  begin
    perform choisir_skin('obsidienne', 'initiale', 'aucune', 'fissure', 'os');
    v_ko := v_ko + 1; raise notice '  KO   2. Obsidienne accordee sans victoires loups';
  exception when others then
    v_ok := v_ok + 1; raise notice '  OK   2. Obsidienne refusee sans stats';
  end;

  -- ═══════════ 3. Apres injection de stats : Obsidienne OK ═══════════
  insert into profil_stats (user_id, victoires_loups) values (v_u, 10)
    on conflict (user_id) do update set victoires_loups = 10;
  begin
    perform choisir_skin('obsidienne', 'initiale', 'aucune', 'fissure', 'os');
    if (select skin_matiere = 'obsidienne' from profils where id = v_u) then
      v_ok := v_ok + 1; raise notice '  OK   3. 10 victoires loups : obsidienne debloquee';
    else
      v_ko := v_ko + 1; raise notice '  KO   3. Matiere non enregistree';
    end if;
  exception when others then
    v_ko := v_ko + 1; raise notice '  KO   3. Obsidienne refusee malgre stats : %', sqlerrm;
  end;

  -- ═══════════ 4. Valeur inconnue -> false (jamais d'exception) ═══════════
  if skin_debloque(v_u, 'matiere', 'licorne') = false
     and skin_debloque(v_u, 'gravure', 'rune_s') = true then
    v_ok := v_ok + 1; raise notice '  OK   4. Valeur inconnue = false, rune libre = true';
  else
    v_ko := v_ko + 1; raise notice '  KO   4. skin_debloque incoherent sur valeur inconnue';
  end if;

  -- ═══════════ 5. Anti-fuite : refus en pleine partie ═══════════
  insert into parties (code, hote_id, statut) values ('123456', v_u, 'nuit')
    returning id into v_partie;
  insert into joueurs_partie (partie_id, user_id, place) values (v_partie, v_u, 1);
  begin
    perform choisir_skin('granit', 'initiale', 'aucune', 'fissure', 'os');
    v_ko := v_ko + 1; raise notice '  KO   5. Skin change alors qu''une partie est en cours';
  exception when others then
    v_ok := v_ok + 1; raise notice '  OK   5. Anti-fuite : atelier ferme en pleine partie';
  end;
  -- partie terminee : l'atelier rouvre
  update parties set statut = 'terminee' where id = v_partie;
  begin
    perform choisir_skin('granit', 'initiale', 'aucune', 'fissure', 'os');
    v_ok := v_ok + 1; raise notice '  OK   6. Partie terminee : atelier de nouveau ouvert';
  exception when others then
    v_ko := v_ko + 1; raise notice '  KO   6. Atelier reste ferme apres la partie : %', sqlerrm;
  end;
  delete from parties where id = v_partie;

  -- ═══════════ 7. Garde-fou RLS : ecriture directe des skin_* bloquee ═══════════
  -- Une ecriture cliente directe est une transaction distincte qui n'a jamais
  -- pose le laissez-passer ; on le remet a zero pour reproduire ce cas ici
  -- (le do-block entier partage une seule transaction).
  perform set_config('loup_garou.skin_ok', '', true);
  begin
    update profils set skin_matiere = 'marbre' where id = v_u;
    v_ko := v_ko + 1; raise notice '  KO   7. skin_* modifiable en contournant choisir_skin';
  exception when others then
    v_ok := v_ok + 1; raise notice '  OK   7. Ecriture directe des skin_* refusee (trigger)';
  end;

  raise notice '  ---- % reussis, % echoues ----', v_ok, v_ko;
end $$;
