\set ON_ERROR_STOP on
\pset pager off
\set QUIET on

-- =====================================================================
--  Tests — Rarete reelle des skins (migration 13_stats_skins_20260719.sql)
--
--  On cree des profils (humains + un bot), on leur pose des skins et des
--  parties jouees, et on verifie que stats_skins() compte les BONS
--  porteurs, ignore le bot et les joueurs sans partie, et rapporte le bon
--  total.
-- =====================================================================

truncate parties, profils, auth.users, profil_stats cascade;

-- 4 humains avec partie(s) jouee(s), 1 humain sans partie, 1 bot.
insert into auth.users (email, raw_user_meta_data)
select 'p' || i || '@t.fr', jsonb_build_object('pseudo', 'Porteur' || i)
from generate_series(1,6) i;

do $$
declare u record; ids uuid[]; v jsonb; v_total int; v_ok int := 0; v_ko int := 0;
begin
  select array_agg(id order by pseudo) into ids from profils;   -- 6 profils créés par trigger

  -- le 6e est un bot
  update profils set est_bot = true where id = ids[6];

  -- parties jouées : humains 1..4 en ont ; le 5e n'a joué aucune partie ; le bot (6) n'a pas de stats
  insert into profil_stats (user_id, parties_jouees) values
    (ids[1], 3), (ids[2], 1), (ids[3], 5), (ids[4], 2), (ids[5], 0);

  -- skins équipés : 3 en granit, 1 en obsidienne (parmi les 4 comptés).
  -- laissez-passer du garde-fou (comme le fait choisir_skin) pour écrire skin_*
  perform set_config('loup_garou.skin_ok', '1', true);
  update profils set skin_matiere = 'granit'     where id in (ids[1], ids[2], ids[4]);
  update profils set skin_matiere = 'obsidienne' where id = ids[3];
  update profils set skin_matiere = 'obsidienne' where id = ids[5];   -- ignoré (0 partie)
  update profils set skin_matiere = 'obsidienne' where id = ids[6];   -- ignoré (bot)

  v := stats_skins();
  v_total := (v->>'total')::int;

  if v_total = 4 then v_ok:=v_ok+1; raise notice '  OK   1. total = 4 (bot et joueur sans partie exclus)';
  else v_ko:=v_ko+1; raise notice '  KO   1. total = % (attendu 4)', v_total; end if;

  if (v->'parts'->>'matiere:granit')::int = 3 then v_ok:=v_ok+1; raise notice '  OK   2. 3 porteurs de granit';
  else v_ko:=v_ko+1; raise notice '  KO   2. granit = % (attendu 3)', v->'parts'->>'matiere:granit'; end if;

  if (v->'parts'->>'matiere:obsidienne')::int = 1 then v_ok:=v_ok+1; raise notice '  OK   3. 1 porteur d''obsidienne (bot + sans-partie ignores)';
  else v_ko:=v_ko+1; raise notice '  KO   3. obsidienne = % (attendu 1)', v->'parts'->>'matiere:obsidienne'; end if;

  -- valeurs par defaut sur les autres categories : les 4 comptes ont bien une teinte 'os'
  if (v->'parts'->>'teinte:os')::int = 4 then v_ok:=v_ok+1; raise notice '  OK   4. 4 porteurs de teinte os (defaut)';
  else v_ko:=v_ko+1; raise notice '  KO   4. teinte:os = % (attendu 4)', v->'parts'->>'teinte:os'; end if;

  raise notice '  ---- % reussis, % echoues ----', v_ok, v_ko;
  if v_ko > 0 then raise exception 'Test stats_skins : % echec(s)', v_ko; end if;
end $$;
