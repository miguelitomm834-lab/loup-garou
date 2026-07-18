-- =====================================================================
--  Migration 02 — Inscription robuste
--
--  Problème : le trigger d'inscription insérait le pseudo brut. Un pseudo
--  trop court, trop long ou déjà pris faisait échouer toute la création du
--  compte avec une erreur de contrainte illisible côté client.
--
--  Correction : on nettoie le pseudo, et on lève un doublon en suffixant
--  au lieu de refuser l'inscription.
-- =====================================================================

create or replace function gerer_nouvel_utilisateur()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pseudo text;
  v_base   text;
  v_i      int := 1;
begin
  -- on ne garde que des caractères raisonnables
  v_pseudo := regexp_replace(
                coalesce(new.raw_user_meta_data->>'pseudo', ''),
                '[^A-Za-zÀ-ÿ0-9_\- ]', '', 'g');
  v_pseudo := btrim(v_pseudo);

  -- trop court : on retombe sur un nom de villageois anonyme
  if char_length(v_pseudo) < 3 then
    v_pseudo := 'Villageois' || substr(replace(new.id::text,'-',''), 1, 6);
  end if;

  v_pseudo := substr(v_pseudo, 1, 20);
  v_base   := v_pseudo;

  -- pseudo déjà pris : on suffixe plutôt que de bloquer l'inscription
  while exists (select 1 from profils where pseudo = v_pseudo) loop
    v_i := v_i + 1;
    v_pseudo := substr(v_base, 1, 20 - char_length(v_i::text) - 1) || '_' || v_i;
    if v_i > 999 then
      v_pseudo := 'Villageois' || substr(replace(gen_random_uuid()::text,'-',''), 1, 8);
      exit;
    end if;
  end loop;

  insert into profils (id, pseudo) values (new.id, v_pseudo);
  return new;
end $$;

-- Permet au joueur de changer de pseudo plus tard, avec les mêmes règles
create or replace function changer_pseudo(p_pseudo text)
returns profils language plpgsql security definer set search_path = public as $$
declare v_p text; v_r profils;
begin
  v_p := btrim(regexp_replace(p_pseudo, '[^A-Za-zÀ-ÿ0-9_\- ]', '', 'g'));
  if char_length(v_p) < 3 then raise exception 'Le pseudo fait 3 caractères minimum'; end if;
  if char_length(v_p) > 20 then raise exception 'Le pseudo fait 20 caractères maximum'; end if;
  if exists (select 1 from profils where pseudo = v_p and id <> auth.uid())
    then raise exception 'Ce pseudo est déjà pris'; end if;

  update profils set pseudo = v_p where id = auth.uid() returning * into v_r;
  return v_r;
end $$;
