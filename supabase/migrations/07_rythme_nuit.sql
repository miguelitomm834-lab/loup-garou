-- =====================================================================
--  Migration 07 — Rythme nuit (Chantier #1 « Rythme nuit »)
--
--  Problème : la nuit « traîne » encore, sans bouton d'accélération côté
--  joueur. Deux causes :
--
--   B) BUG PRINCIPAL — quand AUCUN humain vivant n'a de pouvoir nocturne
--      actif ce cycle (p.ex. le seul humain est villageois et tous les rôles
--      de nuit sont des bots), personne n'appelle agir_nuit. Or c'est agir_nuit
--      qui, via tous_ont_agi, rapproche l'échéance (résolution anticipée).
--      Résultat : rien ne l'écourte et la nuit dure toute sa durée (75 s).
--      Correctif : à CHAQUE entrée en phase 'nuit' (appliquer_phase pour les
--      nuits suivantes ET demarrer_partie pour la nuit 1), si aucun humain
--      vivant n'a de pouvoir nocturne actif ce cycle, on rapproche
--      phase_fin_le d'un court délai. Les bots jouent de toute façon au
--      moment de la résolution (bots_jouent_nuit, appelé DANS resoudre_phase,
--      avant le calcul de la victime — la sorcière-bot peut donc toujours
--      réagir). On ne touche NI resoudre_phase, NI bots_jouent_nuit : l'ordre
--      de jeu des bots et la réaction de la sorcière restent intacts.
--
--   C) DÉLAI « bots 2 à 6 s » — le délai de grâce de la résolution anticipée
--      de nuit devient un aléatoire 2–6 s (impression que les bots
--      « réfléchissent » brièvement), au lieu d'un 2 s fixe. Appliqué (1) au
--      cas B ci-dessus et (2) dans agir_nuit quand tous_ont_agi devient vrai
--      la nuit. Toujours via least(phase_fin_le, …) pour ne JAMAIS rallonger.
--      Le jour (« Passer au vote » = demander_passage) et le vote (voter)
--      gardent leur comportement d'origine : non touchés ici.
--
--  A) tous_ont_agi (migration 03_rythme) est déjà correct : il ne compte que
--     les humains vivants à pouvoir nocturne ACTIF ce cycle (loup_garou,
--     voyante, sorcière si ≥1 fiole, cupidon au cycle 1) — les bots ne
--     bloquent jamais. On le laisse tel quel et on réutilise EXACTEMENT la
--     même définition de « pouvoir actif » dans le helper ci-dessous.
--
--  Fonctions recréées (create or replace, réexécutable) :
--    - humain_doit_agir_nuit(uuid, int)  [nouveau helper booléen]
--    - appliquer_phase(uuid, statut_partie)  [corps recopié de 01_chasseur]
--    - demarrer_partie(uuid)                 [corps recopié de schema_complet]
--    - agir_nuit(uuid, action_nuit, uuid, uuid) [corps recopié de 03_rythme]
--
--  Réexécutable sans casser une base déjà migrée.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Helper : au moins un humain vivant a-t-il un pouvoir nocturne ACTIF
--    ce cycle ? (inverse de « tous les rôles de nuit sont des bots »)
--
--    Même définition de « pouvoir actif » que la branche 'nuit' de
--    tous_ont_agi (migration 03_rythme) :
--      loup_garou (chaque nuit), voyante (chaque nuit),
--      sorciere (si au moins une fiole restante),
--      cupidon (seulement au cycle 1).
--    Villageois et chasseur : aucune action de nuit.
--    On ne regarde que les humains (not est_bot) : un bot ne doit jamais
--    empêcher d'écourter la nuit.
--
--    p_cycle = le cycle de la nuit concernée (nécessaire pour cupidon).
-- ---------------------------------------------------------------------
create or replace function humain_doit_agir_nuit(p_partie uuid, p_cycle integer)
returns boolean language plpgsql security definer stable set search_path = public as $$
begin
  return exists (
    select 1
      from joueurs_partie jp
      join roles_joueurs  r  on r.partie_id = jp.partie_id and r.user_id = jp.user_id
      join profils        pr on pr.id = jp.user_id
     where jp.partie_id = p_partie
       and jp.vivant
       and not pr.est_bot
       and (
            r.role = 'loup_garou'
         or r.role = 'voyante'
         or (r.role = 'sorciere'
             and (r.potion_vie_utilisee = false or r.potion_mort_utilisee = false))
         or (r.role = 'cupidon' and p_cycle = 1)
       )
  );
end $$;

-- ---------------------------------------------------------------------
-- 1. appliquer_phase — recopie FIDÈLE de 01_chasseur, + rythme nuit (B/C).
--    Seuls ajouts : on récupère le cycle après bascule (returning), et si la
--    phase devient 'nuit' sans aucun humain à pouvoir actif, on rapproche
--    l'échéance de 2–6 s (jamais au-delà de l'échéance normale, d'où least).
-- ---------------------------------------------------------------------
create or replace function appliquer_phase(p_partie uuid, p_phase statut_partie)
returns void language plpgsql security definer set search_path = public as $$
declare v_chasseur uuid; v_cycle int;
begin
  select chasseur_en_attente into v_chasseur from parties where id = p_partie;

  if v_chasseur is not null then
    update parties
       set statut = 'chasseur', retour_phase = p_phase,
           phase_fin_le = now() + duree_phase('chasseur')
     where id = p_partie;
    return;
  end if;

  update parties
     set statut = p_phase, retour_phase = null,
         cycle = case when p_phase = 'nuit' then cycle + 1 else cycle end,
         phase_fin_le = now() + duree_phase(p_phase)
   where id = p_partie
  returning cycle into v_cycle;

  -- Rythme nuit (B/C) : si personne d'humain n'a de pouvoir nocturne actif
  -- ce cycle, aucun agir_nuit ne viendra écourter la nuit → on le fait ici,
  -- avec le même délai de grâce aléatoire 2–6 s, sans jamais rallonger.
  if p_phase = 'nuit' and not humain_doit_agir_nuit(p_partie, v_cycle) then
    update parties
       set phase_fin_le = least(phase_fin_le,
                                now() + (2 + random() * 4) * interval '1 second')
     where id = p_partie;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. demarrer_partie — recopie FIDÈLE de schema_complet.sql, + rythme de la
--    nuit 1 (B/C) : même court délai si aucun humain n'a de pouvoir nocturne
--    actif au cycle 1. La durée normale de la nuit 1 (90 s) reste inchangée
--    quand des humains doivent agir.
-- ---------------------------------------------------------------------
create or replace function demarrer_partie(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_partie parties; v_n int; v_loups int; v_roles role_type[]; v_i int := 1; v_j record;
begin
  select * into v_partie from parties where id = p_partie for update;
  if not found then raise exception 'Partie introuvable'; end if;
  if v_partie.hote_id <> auth.uid() then raise exception 'Seul l''hôte peut lancer'; end if;
  if v_partie.statut <> 'lobby' then raise exception 'Partie déjà lancée'; end if;

  select count(*) into v_n from joueurs_partie where partie_id = p_partie;
  if v_n < 6 then raise exception 'Il faut au moins 6 joueurs (actuellement %)', v_n; end if;

  v_loups := greatest(1, round(v_n::numeric / 4)::int);

  v_roles := array_fill('loup_garou'::role_type, array[v_loups]);
  v_roles := v_roles || 'voyante'::role_type;
  if v_n >= 7 then v_roles := v_roles || 'sorciere'::role_type; end if;
  if v_n >= 8 then v_roles := v_roles || 'chasseur'::role_type; end if;
  if v_n >= 9 then v_roles := v_roles || 'cupidon'::role_type;  end if;
  while array_length(v_roles, 1) < v_n loop
    v_roles := v_roles || 'villageois'::role_type;
  end loop;

  -- mélange aléatoire des joueurs, attribution dans l'ordre du tableau
  for v_j in select user_id from joueurs_partie where partie_id = p_partie order by random() loop
    insert into roles_joueurs (partie_id, user_id, role, camp)
    values (p_partie, v_j.user_id, v_roles[v_i],
            case when v_roles[v_i] = 'loup_garou' then 'loups'::camp_type else 'village'::camp_type end);
    v_i := v_i + 1;
  end loop;

  update parties
     set statut = 'nuit', cycle = 1, demarree_le = now(),
         phase_fin_le = now() + interval '90 seconds'
   where id = p_partie;

  -- Rythme nuit 1 (B/C) : si aucun humain vivant n'a de pouvoir nocturne
  -- actif au cycle 1, rapprocher l'échéance de 2–6 s (jamais au-delà de la
  -- durée normale). Les bots jouent au moment de la résolution.
  if not humain_doit_agir_nuit(p_partie, 1) then
    update parties
       set phase_fin_le = least(phase_fin_le,
                                now() + (2 + random() * 4) * interval '1 second')
     where id = p_partie;
  end if;

  update profils set parties_jouees = parties_jouees + 1
   where id in (select user_id from joueurs_partie where partie_id = p_partie);
end $$;

-- ---------------------------------------------------------------------
-- 3. agir_nuit — recopie FIDÈLE de 03_rythme, + délai de grâce nuit 2–6 s (C).
--    Seul changement vs 03_rythme : l'intervalle de la résolution anticipée
--    passe de « 2 seconds » fixe à un aléatoire 2–6 s. On garde le least(…)
--    pour ne JAMAIS repousser l'échéance.
-- ---------------------------------------------------------------------
create or replace function agir_nuit(
  p_partie uuid, p_action action_nuit, p_cible uuid, p_cible2 uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_partie parties; v_role role_type; v_r roles_joueurs;
begin
  select * into v_partie from parties where id = p_partie;
  if v_partie.statut <> 'nuit' then raise exception 'Ce n''est pas la nuit'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = auth.uid() and vivant)
    then raise exception 'Tu es mort ou tu n''es pas dans la partie'; end if;

  select * into v_r from roles_joueurs where partie_id = p_partie and user_id = auth.uid();
  v_role := v_r.role;

  -- vérifie que le rôle a le droit de faire cette action
  if not (
       (p_action = 'devorer'    and v_role = 'loup_garou')
    or (p_action = 'sonder'     and v_role = 'voyante')
    or (p_action in ('potion_vie','potion_mort') and v_role = 'sorciere')
    or (p_action = 'lier'       and v_role = 'cupidon' and v_partie.cycle = 1)
  ) then raise exception 'Action non autorisée pour ton rôle'; end if;

  if p_action = 'potion_vie'  and v_r.potion_vie_utilisee  then raise exception 'Potion de vie déjà utilisée'; end if;
  if p_action = 'potion_mort' and v_r.potion_mort_utilisee then raise exception 'Potion de mort déjà utilisée'; end if;

  -- la cible doit être vivante
  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_cible and vivant)
    then raise exception 'Cible invalide'; end if;

  insert into actions_nuit (partie_id, cycle, acteur_id, action, cible_id, cible2_id)
  values (p_partie, v_partie.cycle, auth.uid(), p_action, p_cible, p_cible2)
  on conflict (partie_id, cycle, acteur_id, action)
  do update set cible_id = excluded.cible_id, cible2_id = excluded.cible2_id;

  -- Résolution anticipée : si plus aucune action humaine n'est en attente,
  -- on écourte la nuit après un court délai de grâce aléatoire 2–6 s
  -- (impression que les bots « réfléchissent »), sans jamais repousser
  -- l'échéance (least).
  if tous_ont_agi(p_partie) then
    update parties
       set phase_fin_le = least(phase_fin_le,
                                now() + (2 + random() * 4) * interval '1 second')
     where id = p_partie;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Droits d'exécution (mêmes conventions que les migrations précédentes)
-- ---------------------------------------------------------------------
grant execute on function humain_doit_agir_nuit(uuid, integer)              to authenticated, service_role;
grant execute on function appliquer_phase(uuid, statut_partie)              to authenticated, service_role;
grant execute on function demarrer_partie(uuid)                             to authenticated;
grant execute on function agir_nuit(uuid, action_nuit, uuid, uuid)          to authenticated;
