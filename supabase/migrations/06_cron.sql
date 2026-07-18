-- =====================================================================
--  Migration 06 — pg_cron : plus aucune partie ne se fige
--
--  Problème : jusqu'ici, seul l'onglet de l'hôte appelait resoudre_phase
--  quand son chrono tombait à zéro. Si l'hôte ferme son onglet, la partie
--  reste bloquée sur phase_fin_le dépassé.
--
--  Correctif : une fonction avancer_parties_en_retard() qui balaie toutes
--  les parties dont l'échéance est passée et les fait avancer, planifiée
--  toutes les 10 s par pg_cron. La résolution anticipée (03_rythme) pose
--  déjà phase_fin_le = now()+2s ; le cron prend le relais si personne n'est
--  là pour déclencher.
--
--  Réexécutable : create extension if not exists, create or replace,
--  cron.unschedule gardé par un bloc qui ignore l'absence du job.
-- =====================================================================

-- pg_cron (disponible sur Supabase ; base postgres, rôle postgres)
create extension if not exists pg_cron;

-- Balaie les parties en retard et les fait avancer. Une partie qui échoue
-- n'interrompt pas le balayage des autres (bloc exception par itération).
create or replace function avancer_parties_en_retard()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select id from parties
     where statut not in ('lobby','terminee')
       and phase_fin_le is not null
       and phase_fin_le < now()
  loop
    begin
      perform resoudre_phase(r.id);
    exception when others then
      null;   -- une partie cassée ne doit pas figer les autres
    end;
  end loop;
end $$;

-- Planification toutes les 10 secondes (dé-planifie d'abord pour l'idempotence)
do $$
begin
  perform cron.unschedule('avancer-parties-loup-garou');
exception when others then
  null;   -- le job n'existait pas encore
end $$;

select cron.schedule('avancer-parties-loup-garou', '10 seconds',
                     $$select avancer_parties_en_retard();$$);
