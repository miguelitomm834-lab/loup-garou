-- =====================================================================
--  Migration 08 — Compteurs d'exploits (Chantier #4 « stats »)
--
--  Objectif : tenir un palmarès public par joueur. Une ligne par humain
--  dans `profil_stats`, alimentée UNIQUEMENT par les fonctions moteur
--  SECURITY DEFINER. Les bots (profils.est_bot = true) n'ont jamais de
--  stats : chaque écriture passe par incr_stat() qui les ignore.
--
--  CONTRAT :
--    - Aucune écriture directe possible côté client : RLS n'autorise que
--      le SELECT (les stats sont publiques, c'est un palmarès). Les
--      INSERT/UPDATE viennent des RPC ci-dessous, propriétaire postgres.
--    - Aucune injection : incr_stat() valide le nom de colonne contre un
--      ensemble FERMÉ (case explicite), jamais de SQL dynamique.
--    - Aucune fuite de rôle : ce fichier n'expose aucune vue ; il ne lit
--      roles_joueurs que dans des fonctions SECURITY DEFINER.
--
--  Fonctions ÉTENDUES (recopie fidèle de la version LIVE + incréments) :
--    - resoudre_phase   : recopie de 05_narrateur.sql (07_rythme_nuit ne la
--                         redéfinit PAS ; la version LIVE reste celle de 05).
--    - tuer_joueur      : recopie de schema.sql (jamais redéfinie en 01→07).
--    - terminer_partie  : recopie de schema.sql (jamais redéfinie en 01→07).
--
--  Noms exacts découverts dans le code existant :
--    - action de la voyante  : 'sonder'            (enum action_nuit)
--    - action des loups      : 'devorer'
--    - cause de dévoration    : 'dévoré'            (avec accent)
--    - camp du village        : 'village'  / loups : 'loups'
--
--  Réexécutable : create table if not exists, create or replace function,
--  alter ... add column if not exists, drop policy if exists.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Table des compteurs (une ligne par humain, créée à la volée)
-- ---------------------------------------------------------------------
create table if not exists profil_stats (
  user_id                       uuid primary key references profils(id) on delete cascade,
  parties_jouees                integer not null default 0,
  victoires_village             integer not null default 0,
  victoires_loups               integer not null default 0,
  victoires_amoureux            integer not null default 0,
  survies_fin_de_partie         integer not null default 0,
  aubes_survecues               integer not null default 0,
  morts_premiere_nuit           integer not null default 0,
  loups_demasques_voyante       integer not null default 0,
  villageois_devores            integer not null default 0,
  pendaisons_loup_premier_vote  integer not null default 0,
  sauvetages_sorciere           integer not null default 0,
  accusations_survecues         integer not null default 0
);

-- Colonnes ajoutées défensivement si la table préexistait (idempotence)
alter table profil_stats add column if not exists parties_jouees               integer not null default 0;
alter table profil_stats add column if not exists victoires_village            integer not null default 0;
alter table profil_stats add column if not exists victoires_loups              integer not null default 0;
alter table profil_stats add column if not exists victoires_amoureux           integer not null default 0;
alter table profil_stats add column if not exists survies_fin_de_partie        integer not null default 0;
alter table profil_stats add column if not exists aubes_survecues              integer not null default 0;
alter table profil_stats add column if not exists morts_premiere_nuit          integer not null default 0;
alter table profil_stats add column if not exists loups_demasques_voyante      integer not null default 0;
alter table profil_stats add column if not exists villageois_devores           integer not null default 0;
alter table profil_stats add column if not exists pendaisons_loup_premier_vote integer not null default 0;
alter table profil_stats add column if not exists sauvetages_sorciere          integer not null default 0;
alter table profil_stats add column if not exists accusations_survecues        integer not null default 0;

-- ---------------------------------------------------------------------
-- 2. RLS — palmarès public en lecture, aucune écriture côté client
-- ---------------------------------------------------------------------
alter table profil_stats enable row level security;

-- Lecture publique (palmarès). AUCUNE policy INSERT/UPDATE/DELETE : les
-- écritures ne passent QUE par incr_stat(), appelée depuis des fonctions
-- SECURITY DEFINER (propriétaire postgres, qui contourne le RLS).
drop policy if exists "stats lisibles" on profil_stats;
create policy "stats lisibles" on profil_stats for select to authenticated
  using (true);

grant select on profil_stats to authenticated, anon;

-- ---------------------------------------------------------------------
-- 3. incr_stat — l'UNIQUE porte d'écriture des compteurs
--
--  Sécurité :
--    - un BOT n'a jamais de stats (filtre profils.est_bot = false) ;
--    - un profil inexistant ou p_user NULL est ignoré ;
--    - le nom de colonne est validé contre un ENSEMBLE FERMÉ (case
--      explicite) : aucune colonne hors liste, aucun SQL dynamique,
--      aucune injection possible.
-- ---------------------------------------------------------------------
create or replace function incr_stat(p_user uuid, p_col text, p_n int default 1)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or p_n = 0 then return; end if;

  -- Jamais de stats pour un bot (ni pour un profil fantôme)
  if not exists (select 1 from profils where id = p_user and est_bot = false) then
    return;
  end if;

  -- Garantit la ligne (une par joueur), puis incrémente la colonne visée.
  insert into profil_stats (user_id) values (p_user)
  on conflict (user_id) do nothing;

  case p_col
    when 'parties_jouees'
      then update profil_stats set parties_jouees = parties_jouees + p_n where user_id = p_user;
    when 'victoires_village'
      then update profil_stats set victoires_village = victoires_village + p_n where user_id = p_user;
    when 'victoires_loups'
      then update profil_stats set victoires_loups = victoires_loups + p_n where user_id = p_user;
    when 'victoires_amoureux'
      then update profil_stats set victoires_amoureux = victoires_amoureux + p_n where user_id = p_user;
    when 'survies_fin_de_partie'
      then update profil_stats set survies_fin_de_partie = survies_fin_de_partie + p_n where user_id = p_user;
    when 'aubes_survecues'
      then update profil_stats set aubes_survecues = aubes_survecues + p_n where user_id = p_user;
    when 'morts_premiere_nuit'
      then update profil_stats set morts_premiere_nuit = morts_premiere_nuit + p_n where user_id = p_user;
    when 'loups_demasques_voyante'
      then update profil_stats set loups_demasques_voyante = loups_demasques_voyante + p_n where user_id = p_user;
    when 'villageois_devores'
      then update profil_stats set villageois_devores = villageois_devores + p_n where user_id = p_user;
    when 'pendaisons_loup_premier_vote'
      then update profil_stats set pendaisons_loup_premier_vote = pendaisons_loup_premier_vote + p_n where user_id = p_user;
    when 'sauvetages_sorciere'
      then update profil_stats set sauvetages_sorciere = sauvetages_sorciere + p_n where user_id = p_user;
    when 'accusations_survecues'
      then update profil_stats set accusations_survecues = accusations_survecues + p_n where user_id = p_user;
    else
      raise exception 'incr_stat : colonne inconnue %', p_col;
  end case;
end $$;

-- ---------------------------------------------------------------------
-- 4. resoudre_phase — RECOPIE FIDÈLE de la version LIVE (05_narrateur.sql,
--    non redéfinie par 07_rythme_nuit), avec les compteurs intercalés.
--
--    Ajouts nuit :
--      - sauvetages_sorciere +1 quand la potion de vie annule une dévoration ;
--      - villageois_devores +1 pour chaque loup vivant si la victime dévorée
--        est du camp village ;
--      - loups_demasques_voyante +1 quand la voyante a sondé un loup ;
--      - aubes_survecues +1 pour chaque vivant à l'issue de la nuit.
--    Ajouts vote :
--      - pendaisons_loup_premier_vote +1 pour chaque votant contre la cible
--        si cycle = 1 et la cible éliminée est un loup ;
--      - accusations_survecues +1 pour tout vivant ayant reçu ≥1 voix sans
--        être éliminé.
-- ---------------------------------------------------------------------
create or replace function resoudre_phase(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p parties; v_victime uuid; v_sauvee boolean; v_empoisonne uuid;
  v_lien actions_nuit; v_lynche uuid; v_max int; v_ex_aequo int;
  v_avant uuid[];
  v_devore uuid; v_rec record;   -- ajouts stats (chantier #4)
begin
  select * into v_p from parties where id = p_partie for update;
  if not found or v_p.statut in ('lobby','terminee') then return; end if;

  -- ═══ Phase chasseur ═══
  if v_p.statut = 'chasseur' then
    if v_p.chasseur_en_attente is not null then
      -- si le chasseur est un bot, il tire immédiatement
      if exists (select 1 from profils where id = v_p.chasseur_en_attente and est_bot) then
        perform bot_tire_chasseur(p_partie, v_p.chasseur_en_attente);
        return;
      end if;
      -- chasseur humain : on attend son tir, sauf si le temps est écoulé
      if v_p.phase_fin_le is null or now() < v_p.phase_fin_le then return; end if;
      update parties set chasseur_en_attente = null where id = p_partie;
    end if;
    perform conclure(p_partie, coalesce(v_p.retour_phase, 'jour'));
    return;
  end if;

  -- ═══ Nuit ═══
  if v_p.statut = 'nuit' then
    perform bots_jouent_nuit(p_partie, v_p.cycle);   -- bots agissent juste avant la résolution

    if v_p.cycle = 1 then
      select * into v_lien from actions_nuit
       where partie_id = p_partie and cycle = 1 and action = 'lier' limit 1;
      if found and v_lien.cible2_id is not null then
        insert into couples (partie_id, joueur_a, joueur_b)
        values (p_partie, v_lien.cible_id, v_lien.cible2_id)
        on conflict (partie_id) do nothing;
      end if;
    end if;

    select cible_id into v_victime from actions_nuit
     where partie_id = p_partie and cycle = v_p.cycle and action = 'devorer'
     group by cible_id order by count(*) desc, random() limit 1;

    select exists (select 1 from actions_nuit
                   where partie_id = p_partie and cycle = v_p.cycle
                     and action = 'potion_vie' and cible_id = v_victime)
      into v_sauvee;
    if v_sauvee then
      update roles_joueurs set potion_vie_utilisee = true
       where partie_id = p_partie and role = 'sorciere';
      -- STAT : la sorcière annule une dévoration (elle a sauvé une vie)
      for v_rec in
        select acteur_id from actions_nuit
         where partie_id = p_partie and cycle = v_p.cycle and action = 'potion_vie'
      loop
        perform incr_stat(v_rec.acteur_id, 'sauvetages_sorciere');
      end loop;
      v_victime := null;
    end if;

    select cible_id into v_empoisonne from actions_nuit
     where partie_id = p_partie and cycle = v_p.cycle and action = 'potion_mort' limit 1;
    if v_empoisonne is not null then
      update roles_joueurs set potion_mort_utilisee = true
       where partie_id = p_partie and role = 'sorciere';
    end if;

    -- Narrateur : photo des vivants juste avant les morts de la nuit
    select coalesce(array_agg(user_id), '{}') into v_avant
      from joueurs_partie where partie_id = p_partie and vivant;

    v_devore := v_victime;   -- STAT : victime réellement dévorée (null si sauvée)
    perform tuer_joueur(p_partie, v_victime, 'dévoré');
    perform tuer_joueur(p_partie, v_empoisonne, 'empoisonné');

    -- Narrateur : lever du jour (victimes + rôles, ou nuit tranquille)
    perform annoncer_bilan(p_partie, v_avant, 'matin');

    -- STAT : la voyante a démasqué un loup (action 'sonder' sur un loup)
    for v_rec in
      select a.acteur_id from actions_nuit a
        join roles_joueurs rc on rc.partie_id = a.partie_id and rc.user_id = a.cible_id
       where a.partie_id = p_partie and a.cycle = v_p.cycle
         and a.action = 'sonder' and rc.camp = 'loups'
    loop
      perform incr_stat(v_rec.acteur_id, 'loups_demasques_voyante');
    end loop;

    -- STAT : villageois dévoré → chaque loup vivant marque un point
    if v_devore is not null
       and exists (select 1 from roles_joueurs
                   where partie_id = p_partie and user_id = v_devore and camp = 'village') then
      for v_rec in
        select jp.user_id from joueurs_partie jp
          join roles_joueurs r on r.partie_id = jp.partie_id and r.user_id = jp.user_id
         where jp.partie_id = p_partie and jp.vivant and r.camp = 'loups'
      loop
        perform incr_stat(v_rec.user_id, 'villageois_devores');
      end loop;
    end if;

    -- STAT : aubes survécues → chaque joueur encore en vie au lever du jour
    for v_rec in
      select user_id from joueurs_partie where partie_id = p_partie and vivant
    loop
      perform incr_stat(v_rec.user_id, 'aubes_survecues');
    end loop;

    perform conclure(p_partie, 'jour');
    return;
  end if;

  -- ═══ Jour ═══
  if v_p.statut = 'jour' then
    perform appliquer_phase(p_partie, 'vote');
    return;
  end if;

  -- ═══ Vote ═══
  if v_p.statut = 'vote' then
    perform bots_votent(p_partie, v_p.cycle);        -- bots votent juste avant le dépouillement

    select count(*) into v_max from votes
     where partie_id = p_partie and cycle = v_p.cycle
     group by cible_id order by count(*) desc limit 1;

    -- Narrateur : photo des vivants juste avant un éventuel lynchage
    select coalesce(array_agg(user_id), '{}') into v_avant
      from joueurs_partie where partie_id = p_partie and vivant;

    if v_max is not null then
      select count(*) into v_ex_aequo from (
        select cible_id from votes
         where partie_id = p_partie and cycle = v_p.cycle
         group by cible_id having count(*) = v_max) t;

      if v_ex_aequo = 1 then
        select cible_id into v_lynche from votes
         where partie_id = p_partie and cycle = v_p.cycle
         group by cible_id having count(*) = v_max;
        perform tuer_joueur(p_partie, v_lynche, 'lynché par le village');
      end if;
    end if;

    -- Narrateur : résultat du vote (pendu + rôle, ou égalité)
    perform annoncer_bilan(p_partie, v_avant, 'vote');

    -- STAT : pendaison d'un loup au tout premier vote → chaque votant
    -- ayant visé la cible éliminée marque un point (cycle 1, cible = loup).
    if v_p.cycle = 1 and v_lynche is not null
       and exists (select 1 from roles_joueurs
                   where partie_id = p_partie and user_id = v_lynche and camp = 'loups') then
      for v_rec in
        select votant_id from votes
         where partie_id = p_partie and cycle = v_p.cycle and cible_id = v_lynche
      loop
        perform incr_stat(v_rec.votant_id, 'pendaisons_loup_premier_vote');
      end loop;
    end if;

    -- STAT : accusations survécues → tout vivant ayant reçu ≥1 voix sans
    -- être éliminé (il est encore en vie après le dépouillement).
    for v_rec in
      select distinct v.cible_id as uid from votes v
       where v.partie_id = p_partie and v.cycle = v_p.cycle
         and exists (select 1 from joueurs_partie jp
                     where jp.partie_id = p_partie and jp.user_id = v.cible_id and jp.vivant)
    loop
      perform incr_stat(v_rec.uid, 'accusations_survecues');
    end loop;

    perform conclure(p_partie, 'nuit');
    return;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. tuer_joueur — RECOPIE FIDÈLE de schema.sql (jamais redéfinie en 01→07)
--    + compteur : morts_premiere_nuit quand un joueur est dévoré au cycle 1.
-- ---------------------------------------------------------------------
create or replace function tuer_joueur(p_partie uuid, p_cible uuid, p_cause text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cycle int; v_role role_type; v_amoureux uuid;
begin
  if p_cible is null then return; end if;
  select cycle into v_cycle from parties where id = p_partie;

  update joueurs_partie
     set vivant = false, mort_au_cycle = v_cycle, cause_mort = p_cause
   where partie_id = p_partie and user_id = p_cible and vivant;
  if not found then return; end if;

  -- STAT : mort dès la première nuit, par dévoration
  if v_cycle = 1 and p_cause = 'dévoré' then
    perform incr_stat(p_cible, 'morts_premiere_nuit');
  end if;

  select role into v_role from roles_joueurs where partie_id = p_partie and user_id = p_cible;
  if v_role = 'chasseur' then
    update parties set chasseur_en_attente = p_cible where id = p_partie;
  end if;

  -- chagrin d'amour
  select case when joueur_a = p_cible then joueur_b else joueur_a end
    into v_amoureux
    from couples where partie_id = p_partie and p_cible in (joueur_a, joueur_b);
  if v_amoureux is not null then
    perform tuer_joueur(p_partie, v_amoureux, 'chagrin d''amour');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. terminer_partie — RECOPIE FIDÈLE de schema.sql (jamais redéfinie
--    en 01→07) + compteurs de fin de partie :
--      - parties_jouees +1 pour tous les joueurs humains ;
--      - victoires_village / _loups / _amoureux +1 pour le camp vainqueur ;
--      - survies_fin_de_partie +1 pour les vivants.
-- ---------------------------------------------------------------------
create or replace function terminer_partie(p_partie uuid, p_vainqueur camp_vainqueur)
returns void language plpgsql security definer set search_path = public as $$
declare v_rec record;   -- ajout stats (chantier #4)
begin
  update parties
     set statut = 'terminee', vainqueur = p_vainqueur,
         terminee_le = now(), phase_fin_le = null
   where id = p_partie;

  -- points de lune : 100 pour les gagnants, 25 de participation
  update profils p set points_lune = p.points_lune + 25
   where p.id in (select user_id from joueurs_partie where partie_id = p_partie);

  update profils p set points_lune = p.points_lune + 75, victoires = p.victoires + 1
   where p.id in (
     select j.user_id from joueurs_partie j
       join roles_joueurs r on r.partie_id = j.partie_id and r.user_id = j.user_id
      where j.partie_id = p_partie
        and case p_vainqueur
              when 'loups'   then r.camp = 'loups'
              when 'village' then r.camp = 'village'
              when 'amoureux' then j.user_id in (
                select unnest(array[joueur_a, joueur_b]) from couples where partie_id = p_partie)
            end
   );

  -- STAT : une partie jouée pour chaque participant (bots ignorés par incr_stat)
  for v_rec in
    select user_id from joueurs_partie where partie_id = p_partie
  loop
    perform incr_stat(v_rec.user_id, 'parties_jouees');
  end loop;

  -- STAT : victoire pour chaque joueur du camp vainqueur
  for v_rec in
    select j.user_id from joueurs_partie j
      join roles_joueurs r on r.partie_id = j.partie_id and r.user_id = j.user_id
     where j.partie_id = p_partie
       and case p_vainqueur
             when 'loups'   then r.camp = 'loups'
             when 'village' then r.camp = 'village'
             when 'amoureux' then j.user_id in (
               select unnest(array[joueur_a, joueur_b]) from couples where partie_id = p_partie)
           end
  loop
    perform incr_stat(v_rec.user_id, case p_vainqueur
      when 'loups'    then 'victoires_loups'
      when 'village'  then 'victoires_village'
      when 'amoureux' then 'victoires_amoureux'
    end);
  end loop;

  -- STAT : survie jusqu'à la fin de partie pour chaque joueur encore vivant
  for v_rec in
    select user_id from joueurs_partie where partie_id = p_partie and vivant
  loop
    perform incr_stat(v_rec.user_id, 'survies_fin_de_partie');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 7. Droits d'exécution (mêmes conventions que les migrations précédentes).
--    incr_stat n'est appelée que depuis des fonctions SECURITY DEFINER,
--    mais on accorde EXECUTE par cohérence avec le reste du schéma.
-- ---------------------------------------------------------------------
grant execute on function incr_stat(uuid, text, int)              to authenticated, service_role;
grant execute on function resoudre_phase(uuid)                    to authenticated, service_role;
grant execute on function tuer_joueur(uuid, uuid, text)           to authenticated, service_role;
grant execute on function terminer_partie(uuid, camp_vainqueur)   to authenticated, service_role;
