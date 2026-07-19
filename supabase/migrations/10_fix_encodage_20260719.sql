-- =====================================================================
--  Migration 10 - Reparation encodage (hotfix)
--
--  La migration 08 appliquee via l'editeur SQL du dashboard a subi une
--  corruption d'encodage des accents (ex. 'devore' stocke "d[mojibake]vor[mojibake]").
--  Ce fichier est 100% ASCII : tous les litteraux accentues sont ecrits
--  en echappements Unicode Postgres (U&'...\00e9...'), inalterables par
--  copier-coller. Il :
--    1) redefinit tuer_joueur et resoudre_phase (versions 08) avec des
--       litteraux surs ;
--    2) repare les cause_mort deja corrompues en base.
-- =====================================================================
-- 4. resoudre_phase  RECOPIE FIDLE de la version LIVE (05_narrateur.sql,
--    non redfinie par 07_rythme_nuit), avec les compteurs intercals.
--
--    Ajouts nuit :
--      - sauvetages_sorciere +1 quand la potion de vie annule une dvoration ;
--      - villageois_devores +1 pour chaque loup vivant si la victime dvore
--        est du camp village ;
--      - loups_demasques_voyante +1 quand la voyante a sond un loup ;
--      - aubes_survecues +1 pour chaque vivant  l'issue de la nuit.
--    Ajouts vote :
--      - pendaisons_loup_premier_vote +1 pour chaque votant contre la cible
--        si cycle = 1 et la cible limine est un loup ;
--      - accusations_survecues +1 pour tout vivant ayant reu 1 voix sans
--        tre limin.
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

  --  Phase chasseur 
  if v_p.statut = 'chasseur' then
    if v_p.chasseur_en_attente is not null then
      -- si le chasseur est un bot, il tire immdiatement
      if exists (select 1 from profils where id = v_p.chasseur_en_attente and est_bot) then
        perform bot_tire_chasseur(p_partie, v_p.chasseur_en_attente);
        return;
      end if;
      -- chasseur humain : on attend son tir, sauf si le temps est coul
      if v_p.phase_fin_le is null or now() < v_p.phase_fin_le then return; end if;
      update parties set chasseur_en_attente = null where id = p_partie;
    end if;
    perform conclure(p_partie, coalesce(v_p.retour_phase, 'jour'));
    return;
  end if;

  --  Nuit 
  if v_p.statut = 'nuit' then
    perform bots_jouent_nuit(p_partie, v_p.cycle);   -- bots agissent juste avant la rsolution

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
      -- STAT : la sorcire annule une dvoration (elle a sauv une vie)
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

    v_devore := v_victime;   -- STAT : victime rellement dvore (null si sauve)
    perform tuer_joueur(p_partie, v_victime, U&'d\00e9vor\00e9');
    perform tuer_joueur(p_partie, v_empoisonne, U&'empoisonn\00e9');

    -- Narrateur : lever du jour (victimes + rles, ou nuit tranquille)
    perform annoncer_bilan(p_partie, v_avant, 'matin');

    -- STAT : la voyante a dmasqu un loup (action 'sonder' sur un loup)
    for v_rec in
      select a.acteur_id from actions_nuit a
        join roles_joueurs rc on rc.partie_id = a.partie_id and rc.user_id = a.cible_id
       where a.partie_id = p_partie and a.cycle = v_p.cycle
         and a.action = 'sonder' and rc.camp = 'loups'
    loop
      perform incr_stat(v_rec.acteur_id, 'loups_demasques_voyante');
    end loop;

    -- STAT : villageois dvor  chaque loup vivant marque un point
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

    -- STAT : aubes survcues  chaque joueur encore en vie au lever du jour
    for v_rec in
      select user_id from joueurs_partie where partie_id = p_partie and vivant
    loop
      perform incr_stat(v_rec.user_id, 'aubes_survecues');
    end loop;

    perform conclure(p_partie, 'jour');
    return;
  end if;

  --  Jour 
  if v_p.statut = 'jour' then
    perform appliquer_phase(p_partie, 'vote');
    return;
  end if;

  --  Vote 
  if v_p.statut = 'vote' then
    perform bots_votent(p_partie, v_p.cycle);        -- bots votent juste avant le dpouillement

    select count(*) into v_max from votes
     where partie_id = p_partie and cycle = v_p.cycle
     group by cible_id order by count(*) desc limit 1;

    -- Narrateur : photo des vivants juste avant un ventuel lynchage
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
        perform tuer_joueur(p_partie, v_lynche, U&'lynch\00e9 par le village');
      end if;
    end if;

    -- Narrateur : rsultat du vote (pendu + rle, ou galit)
    perform annoncer_bilan(p_partie, v_avant, 'vote');

    -- STAT : pendaison d'un loup au tout premier vote  chaque votant
    -- ayant vis la cible limine marque un point (cycle 1, cible = loup).
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

    -- STAT : accusations survcues  tout vivant ayant reu 1 voix sans
    -- tre limin (il est encore en vie aprs le dpouillement).
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
-- 5. tuer_joueur  RECOPIE FIDLE de schema.sql (jamais redfinie en 0107)
--    + compteur : morts_premiere_nuit quand un joueur est dvor au cycle 1.
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

  -- STAT : mort ds la premire nuit, par dvoration
  if v_cycle = 1 and p_cause = U&'d\00e9vor\00e9' then
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

-- ---------------------------------------------------------------------
-- Reparation des donnees deja corrompues (cause_mort)
-- ---------------------------------------------------------------------
update joueurs_partie
   set cause_mort = U&'d\00e9vor\00e9'
 where cause_mort = U&'d\221a\00a9vor\221a\00a9';

update joueurs_partie
   set cause_mort = U&'empoisonn\00e9'
 where cause_mort = U&'empoisonn\221a\00a9';

update joueurs_partie
   set cause_mort = U&'lynch\00e9 par le village'
 where cause_mort = U&'lynch\221a\00a9 par le village';
