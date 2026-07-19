-- =====================================================================
--  Migration 13 - Rarete reelle des skins (Chantier FORGE-C)
--
--  Les « portee par X % des tailleurs » doivent refleter la REALITE, pas
--  un chiffre invente. Cette fonction agrege, sur les profils NON-BOTS
--  ayant au moins une partie jouee, le nombre de porteurs de chaque
--  valeur de skin equipee, plus le total de ces joueurs.
--
--  Retour : { "total": N, "parts": { "matiere:granit": 12, ... } }.
--  Le client n'affichera un pourcentage que si total >= 50 (sinon un
--  ratio a 3 joueurs serait trompeur). Lecture publique authentifiee ;
--  SECURITY DEFINER pour agreger au-dela du RLS, mais n'expose QUE des
--  comptes agreges — aucune donnee nominative.
-- =====================================================================

create or replace function stats_skins()
returns jsonb
language sql stable security definer set search_path = public as $$
  with joueurs as (
    select p.skin_matiere, p.skin_gravure, p.skin_aura, p.skin_mort, p.skin_teinte
      from profils p
      join profil_stats s on s.user_id = p.id
     where p.est_bot = false and s.parties_jouees >= 1
  )
  select jsonb_build_object(
    'total', (select count(*) from joueurs),
    'parts', (
      select coalesce(jsonb_object_agg(k, n), '{}'::jsonb)
      from (
        select 'matiere:' || skin_matiere as k, count(*) as n from joueurs group by skin_matiere
        union all select 'gravure:' || skin_gravure, count(*) from joueurs group by skin_gravure
        union all select 'aura:'    || skin_aura,    count(*) from joueurs group by skin_aura
        union all select 'mort:'    || skin_mort,    count(*) from joueurs group by skin_mort
        union all select 'teinte:'  || skin_teinte,  count(*) from joueurs group by skin_teinte
      ) t
    )
  );
$$;

grant execute on function stats_skins() to authenticated, anon;
