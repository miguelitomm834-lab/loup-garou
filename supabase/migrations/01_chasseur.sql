-- =====================================================================
--  Migration 01 — Correction du blocage après le tir du chasseur
--
--  Problème : resoudre_phase() ne traitait que 'nuit', 'jour' et 'vote'.
--  Quand le chasseur mourait, la partie passait en statut 'chasseur' et
--  plus rien ne la faisait repartir : partie figée définitivement.
--
--  Correction : on mémorise la phase à reprendre dans parties.retour_phase,
--  et toute transition passe désormais par appliquer_phase(), qui détourne
--  automatiquement vers le chasseur quand il y en a un en attente.
-- =====================================================================

alter table parties add column if not exists retour_phase statut_partie;

-- Durée de chaque phase, en un seul endroit
create or replace function duree_phase(p_phase statut_partie)
returns interval language sql immutable as $$
  select case p_phase
    when 'nuit'     then interval '90 seconds'
    when 'jour'     then interval '180 seconds'
    when 'vote'     then interval '60 seconds'
    when 'chasseur' then interval '30 seconds'
    else null end;
$$;

-- Applique une transition. Si un chasseur doit tirer, on l'intercale
-- et on garde en mémoire la phase prévue.
create or replace function appliquer_phase(p_partie uuid, p_phase statut_partie)
returns void language plpgsql security definer set search_path = public as $$
declare v_chasseur uuid;
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
   where id = p_partie;
end $$;

-- Vérifie la victoire puis enchaîne, en laissant le chasseur passer avant.
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
    perform terminer_partie(p_partie, v_gagnant);
    return;
  end if;

  perform appliquer_phase(p_partie, p_phase);
end $$;

-- Moteur principal, réécrit
create or replace function resoudre_phase(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p parties; v_victime uuid; v_sauvee boolean; v_empoisonne uuid;
  v_lien actions_nuit; v_lynche uuid; v_max int; v_ex_aequo int;
begin
  select * into v_p from parties where id = p_partie for update;
  if not found or v_p.statut in ('lobby','terminee') then return; end if;

  -- ═══ Phase chasseur ═══
  if v_p.statut = 'chasseur' then
    if v_p.chasseur_en_attente is not null then
      -- il n'a pas encore tiré : on attend, sauf si le temps est écoulé
      if v_p.phase_fin_le is null or now() < v_p.phase_fin_le then return; end if;
      update parties set chasseur_en_attente = null where id = p_partie;
    end if;
    perform conclure(p_partie, coalesce(v_p.retour_phase, 'jour'));
    return;
  end if;

  -- ═══ Nuit ═══
  if v_p.statut = 'nuit' then
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

    perform tuer_joueur(p_partie, v_victime, 'dévoré');
    perform tuer_joueur(p_partie, v_empoisonne, 'empoisonné');
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
    select count(*) into v_max from votes
     where partie_id = p_partie and cycle = v_p.cycle
     group by cible_id order by count(*) desc limit 1;

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

    perform conclure(p_partie, 'nuit');
    return;
  end if;
end $$;

-- Le tir lui-même : on tue, on désarme, puis on laisse le moteur reprendre
create or replace function tirer_chasseur(p_partie uuid, p_cible uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_partie parties;
begin
  select * into v_partie from parties where id = p_partie;
  if v_partie.statut <> 'chasseur' or v_partie.chasseur_en_attente is distinct from auth.uid()
    then raise exception 'Ce n''est pas à toi de tirer'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_cible and vivant)
    then raise exception 'Cible invalide'; end if;

  perform tuer_joueur(p_partie, p_cible, 'abattu par le chasseur');
  update parties set chasseur_en_attente = null where id = p_partie;
  perform conclure(p_partie, coalesce(v_partie.retour_phase, 'jour'));
end $$;
