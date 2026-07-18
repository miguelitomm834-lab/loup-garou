-- =====================================================================
--  Migration 05 — Narrateur (Chantier #2 du cahier des charges V2)
--
--  Objectif : à chaque transition de phase, un message SYSTÈME (ton de
--  conteur) est inséré dans le chat Village pour raconter la partie —
--  qui est mort, comment, avec quel rôle révélé, qui a gagné.
--
--  CONTRAT avec le client (déjà convenu) :
--    Un message système = une ligne de `messages` avec `user_id` NULL et
--    `canal = 'village'`. Le client détecte `user_id is null` pour l'afficher
--    en italique doré (ton de conteur). AUCUN nouveau champ n'est ajouté.
--
--  Ce fichier :
--    1) rend messages.user_id NULLable + fonction inserer_message_systeme ;
--    2) libelle_role() pour révéler un rôle en français ;
--    3) ÉTEND la version LIVE de resoudre_phase (celle de 03_bots) et de
--       conclure (celle de 01_chasseur) pour émettre le récit ;
--    4) fait parler le tir du chasseur (tirer_chasseur + bot_tire_chasseur).
--
--  Détection des morts : on PHOTOGRAPHIE les vivants juste AVANT les
--  appels à tuer_joueur d'une phase (tableau v_avant), puis on compare aux
--  vivants restants. Les « nouveaux morts » de cette phase = ceux présents
--  dans v_avant et désormais non-vivants. C'est fiable même quand plusieurs
--  morts partagent le même cycle (dévoré + empoisonné + chagrin, ou lynché
--  + chagrin) et indépendant du libellé exact de cause_mort. La cause_mort
--  n'est utilisée QUE pour choisir la tournure (dévoré/empoisonné → matin,
--  lynché → gibet, chagrin d'amour → chagrin, abattu par le chasseur → tir).
--
--  Réexécutable sans casser une base déjà migrée (create or replace ;
--  alter ... drop not null est un no-op si la colonne est déjà nullable).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Messages système : user_id NULL autorisé + fonction d'insertion
-- ---------------------------------------------------------------------
--  Rendre user_id nullable. No-op sans erreur si déjà nullable.
--  La clé étrangère messages.user_id -> profils(id) tolère déjà NULL
--  (un FK n'exige pas la présence d'une valeur : NULL = « pas de ligne
--  référencée »), rien d'autre à modifier.
alter table messages alter column user_id drop not null;

--  Insère un message système dans le canal Village de la partie.
--  SECURITY DEFINER (propriétaire postgres) → contourne le RLS d'INSERT,
--  exactement comme les autres RPC qui écrivent dans messages.
create or replace function inserer_message_systeme(p_partie uuid, p_texte text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_texte is null or btrim(p_texte) = '' then return; end if;
  insert into messages (partie_id, user_id, canal, contenu)
  values (p_partie, null, 'village', substr(btrim(p_texte), 1, 500));
end $$;

-- ---------------------------------------------------------------------
-- 2. Libellé français d'un rôle (pour le révéler à la mort)
-- ---------------------------------------------------------------------
create or replace function libelle_role(r role_type)
returns text language sql immutable as $$
  select case r
    when 'loup_garou' then 'Loup-Garou'
    when 'villageois' then 'Villageois'
    when 'voyante'    then 'Voyante'
    when 'sorciere'   then 'Sorcière'
    when 'chasseur'   then 'Chasseur'
    when 'cupidon'    then 'Cupidon'
    else r::text
  end;
$$;

-- Petit utilitaire : pseudo d'un joueur
create or replace function pseudo_de(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select pseudo from profils where id = p_user;
$$;

-- ---------------------------------------------------------------------
-- 3. Annonce d'UNE mort — la tournure dépend de cause_mort
--    (au moins 3 variantes tirées au hasard par situation)
-- ---------------------------------------------------------------------
create or replace function annoncer_mort(p_partie uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cause    text;
  v_nom      text;
  v_role     text;
  v_amoureux text;
  v_texte    text;
begin
  select cause_mort into v_cause
    from joueurs_partie where partie_id = p_partie and user_id = p_user;
  v_nom := pseudo_de(p_user);
  select libelle_role(role) into v_role
    from roles_joueurs where partie_id = p_partie and user_id = p_user;

  if v_cause = 'chagrin d''amour' then
    -- l'amoureux dont la mort a emporté celui-ci
    select pseudo_de(case when joueur_a = p_user then joueur_b else joueur_a end)
      into v_amoureux
      from couples where partie_id = p_partie and p_user in (joueur_a, joueur_b);
    v_texte := case (floor(random()*3))::int
      when 0 then v_nom || ' ne survit pas à la mort de ' || coalesce(v_amoureux, 'son aimé') || '. Le chagrin l''emporte.'
      when 1 then 'Le cœur brisé, ' || v_nom || ' rejoint ' || coalesce(v_amoureux, 'son aimé') || ' dans la mort.'
      else        'On n''aime qu''une fois : ' || v_nom || ' s''éteint auprès de ' || coalesce(v_amoureux, 'son aimé') || '.'
    end;

  elsif v_cause = 'lynché par le village' then
    v_texte := case (floor(random()*3))::int
      when 0 then 'Le village a tranché. ' || v_nom || ' est pendu haut et court. Il était ' || v_role || '.'
      when 1 then 'La corde se tend. ' || v_nom || ' n''ira pas plus loin. Il était ' || v_role || '.'
      else        'Sous les huées, ' || v_nom || ' monte à l''échafaud. Il était ' || v_role || '.'
    end;

  elsif v_cause = 'abattu par le chasseur' then
    v_texte := case (floor(random()*3))::int
      when 0 then 'D''un dernier souffle, le chasseur ajuste et abat ' || v_nom || '. Il était ' || v_role || '.'
      when 1 then 'Le coup de feu claque : ' || v_nom || ' s''effondre. Il était ' || v_role || '.'
      else        'Le chasseur emporte ' || v_nom || ' dans sa chute. Il était ' || v_role || '.'
    end;

  else
    -- dévoré / empoisonné : découverte au lever du jour
    v_texte := case (floor(random()*3))::int
      when 0 then 'Au petit matin, on retrouve ' || v_nom || ' devant sa porte. Il était ' || v_role || '.'
      when 1 then 'Le village s''éveille dans le silence. ' || v_nom || ' ne se réveillera pas. Il était ' || v_role || '.'
      else        'On a retrouvé ' || v_nom || ' à l''aube, la gorge ouverte. Il était ' || v_role || '.'
    end;
  end if;

  perform inserer_message_systeme(p_partie, v_texte);
end $$;

-- ---------------------------------------------------------------------
-- 4. Bilan d'une phase meurtrière : annonce chaque nouveau mort, gère le
--    cas « personne » et la chute du chasseur (qui trouve encore son fusil)
--    p_avant   : tableau des vivants photographié AVANT les tuer_joueur
--    p_contexte: 'matin' (lever du jour) ou 'vote' (dépouillement)
-- ---------------------------------------------------------------------
create or replace function annoncer_bilan(p_partie uuid, p_avant uuid[], p_contexte text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_chasseur uuid;
  v_rec      record;
  v_nb       int := 0;
begin
  select chasseur_en_attente into v_chasseur from parties where id = p_partie;

  -- Les nouveaux morts de la phase (présents avant, morts maintenant),
  -- morts d'abord « directs » puis morts « par chagrin » ; le chasseur qui
  -- vient de tomber est réservé à sa réplique dédiée (son fusil).
  for v_rec in
    select jp.user_id
      from joueurs_partie jp
     where jp.partie_id = p_partie
       and not jp.vivant
       and jp.user_id = any(p_avant)
       and jp.user_id is distinct from v_chasseur
     order by (jp.cause_mort = 'chagrin d''amour'), jp.mort_au_cycle
  loop
    perform annoncer_mort(p_partie, v_rec.user_id);
    v_nb := v_nb + 1;
  end loop;

  -- Personne (hors chasseur en sursis) n'est mort
  if v_nb = 0 and v_chasseur is null then
    if p_contexte = 'matin' then
      perform inserer_message_systeme(p_partie, case (floor(random()*3))::int
        when 0 then 'Le soleil se lève sur un village intact. Cette nuit, personne n''a péri.'
        when 1 then 'Étrangement, tout le monde répond à l''appel ce matin.'
        else        'L''aube est douce : aucune victime cette nuit.'
      end);
    else
      perform inserer_message_systeme(p_partie, case (floor(random()*3))::int
        when 0 then 'Les voix se sont partagées. Le village n''a pas su choisir, et personne ne meurt.'
        when 1 then 'Faute de majorité, la corde reste vide aujourd''hui.'
        else        'Le village hésite, se déchire, et finalement épargne tout le monde.'
      end);
    end if;
  end if;

  -- Le chasseur vient de tomber : il lui reste une balle
  if v_chasseur is not null then
    perform inserer_message_systeme(p_partie, case (floor(random()*3))::int
      when 0 then pseudo_de(v_chasseur) || ' tombe, mais sa main trouve encore son fusil.'
      when 1 then 'Touché à mort, ' || pseudo_de(v_chasseur) || ' arme une dernière fois son fusil.'
      else        pseudo_de(v_chasseur) || ' s''écroule — et pointe son fusil vers la foule.'
    end);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. conclure — recopie fidèle de 01_chasseur + récit :
--    victoire annoncée avant terminer_partie ; tombée de la nuit annoncée
--    quand la partie enchaîne réellement vers une nouvelle nuit.
-- ---------------------------------------------------------------------
create or replace function conclure(p_partie uuid, p_phase statut_partie)
returns void language plpgsql security definer set search_path = public as $$
declare v_gagnant camp_vainqueur;
begin
  -- un chasseur en attente tire avant qu'on décide de quoi que ce soit
  if exists (select 1 from parties where id = p_partie and chasseur_en_attente is not null) then
    perform appliquer_phase(p_partie, p_phase);
    return;
  end if;

  v_gagnant := verifier_victoire(p_partie);
  if v_gagnant is not null then
    -- ═══ Narrateur : fin de partie ═══
    perform inserer_message_systeme(p_partie, case v_gagnant
      when 'village' then case (floor(random()*3))::int
        when 0 then 'Le dernier loup est terrassé. Le village peut enfin dormir en paix. Victoire des Villageois !'
        when 1 then 'Les crocs se sont tus. Le village a triomphé.'
        else        'À l''aube, plus aucun loup ne rôde. Le village l''emporte.'
      end
      when 'loups' then case (floor(random()*3))::int
        when 0 then 'Les loups sont désormais les maîtres du village. Victoire des Loups-Garous !'
        when 1 then 'Il ne reste que des crocs et du sang : les Loups-Garous ont gagné.'
        else        'Le village s''éteint dans les hurlements. Les loups triomphent.'
      end
      when 'amoureux' then case (floor(random()*3))::int
        when 0 then 'Contre tous les camps, les deux amoureux restent seuls au monde. Victoire de l''Amour !'
        when 1 then 'Le village et les loups ont péri : seuls les amoureux survivent. Victoire des Amoureux !'
        else        'Leur amour a survécu à tout. Les amoureux l''emportent.'
      end
    end);
    perform terminer_partie(p_partie, v_gagnant);
    return;
  end if;

  -- ═══ Narrateur : tombée de la nuit (la partie continue vers une nuit) ═══
  if p_phase = 'nuit' then
    perform inserer_message_systeme(p_partie, case (floor(random()*3))::int
      when 0 then 'La nuit tombe. Le village ferme ses volets.'
      when 1 then 'Les lampes s''éteignent une à une. Que ceux qui chassent se réveillent.'
      else        'L''obscurité s''installe. Le village retient son souffle.'
    end);
  end if;

  perform appliquer_phase(p_partie, p_phase);
end $$;

-- ---------------------------------------------------------------------
-- 6. resoudre_phase — RECOPIE FIDÈLE de la version LIVE (03_bots), avec
--    les appels narrateur intercalés aux bons endroits.
-- ---------------------------------------------------------------------
create or replace function resoudre_phase(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p parties; v_victime uuid; v_sauvee boolean; v_empoisonne uuid;
  v_lien actions_nuit; v_lynche uuid; v_max int; v_ex_aequo int;
  v_avant uuid[];
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

    perform tuer_joueur(p_partie, v_victime, 'dévoré');
    perform tuer_joueur(p_partie, v_empoisonne, 'empoisonné');

    -- Narrateur : lever du jour (victimes + rôles, ou nuit tranquille)
    perform annoncer_bilan(p_partie, v_avant, 'matin');

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

    perform conclure(p_partie, 'nuit');
    return;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. tirer_chasseur — recopie fidèle de 01_chasseur + annonce du mort
--    que le chasseur emporte (et de son éventuel amoureux).
-- ---------------------------------------------------------------------
create or replace function tirer_chasseur(p_partie uuid, p_cible uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_partie parties; v_avant uuid[]; v_rec record;
begin
  select * into v_partie from parties where id = p_partie;
  if v_partie.statut <> 'chasseur' or v_partie.chasseur_en_attente is distinct from auth.uid()
    then raise exception 'Ce n''est pas à toi de tirer'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_cible and vivant)
    then raise exception 'Cible invalide'; end if;

  select coalesce(array_agg(user_id), '{}') into v_avant
    from joueurs_partie where partie_id = p_partie and vivant;

  perform tuer_joueur(p_partie, p_cible, 'abattu par le chasseur');

  -- Narrateur : le mort emporté par le chasseur (+ amoureux éventuel)
  for v_rec in
    select jp.user_id
      from joueurs_partie jp
     where jp.partie_id = p_partie and not jp.vivant and jp.user_id = any(v_avant)
     order by (jp.cause_mort = 'chagrin d''amour'), jp.mort_au_cycle
  loop
    perform annoncer_mort(p_partie, v_rec.user_id);
  end loop;

  update parties set chasseur_en_attente = null where id = p_partie;
  perform conclure(p_partie, coalesce(v_partie.retour_phase, 'jour'));
end $$;

-- ---------------------------------------------------------------------
-- 8. bot_tire_chasseur — recopie fidèle de 03_bots + même annonce.
-- ---------------------------------------------------------------------
create or replace function bot_tire_chasseur(p_partie uuid, p_bot uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_p parties; v_cible uuid; v_avant uuid[]; v_rec record;
begin
  select * into v_p from parties where id = p_partie;

  select coalesce(array_agg(user_id), '{}') into v_avant
    from joueurs_partie where partie_id = p_partie and vivant;

  select jp.user_id into v_cible
    from joueurs_partie jp
   where jp.partie_id = p_partie and jp.vivant and jp.user_id <> p_bot
   order by random() limit 1;
  if v_cible is not null then
    perform tuer_joueur(p_partie, v_cible, 'abattu par le chasseur');
  end if;

  -- Narrateur : le mort emporté par le chasseur (+ amoureux éventuel)
  for v_rec in
    select jp.user_id
      from joueurs_partie jp
     where jp.partie_id = p_partie and not jp.vivant and jp.user_id = any(v_avant)
     order by (jp.cause_mort = 'chagrin d''amour'), jp.mort_au_cycle
  loop
    perform annoncer_mort(p_partie, v_rec.user_id);
  end loop;

  update parties set chasseur_en_attente = null where id = p_partie;
  perform conclure(p_partie, coalesce(v_p.retour_phase, 'jour'));
end $$;

-- ---------------------------------------------------------------------
-- 9. Droits d'exécution (mêmes conventions que les migrations précédentes)
--    Ces fonctions sont appelées depuis des fonctions SECURITY DEFINER,
--    mais on accorde EXECUTE par cohérence avec le reste du schéma.
-- ---------------------------------------------------------------------
grant execute on function inserer_message_systeme(uuid, text) to authenticated, service_role;
grant execute on function libelle_role(role_type)             to authenticated, service_role;
grant execute on function pseudo_de(uuid)                     to authenticated, service_role;
grant execute on function annoncer_mort(uuid, uuid)           to authenticated, service_role;
grant execute on function annoncer_bilan(uuid, uuid[], text)  to authenticated, service_role;
