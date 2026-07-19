-- =====================================================================
--  Migration 11 - Reparation encodage des messages de choisir_skin
--
--  Meme cause que la migration 10 : le collage de 09_skins via l'editeur
--  SQL du dashboard a corrompu les accents des messages raise exception
--  (ex. "Mati[mojibake]re verrouill[mojibake]e"). La fonction refusait bien,
--  mais le texte affiche au joueur etait illisible.
--
--  Ce fichier redefinit choisir_skin a l'IDENTIQUE (meme logique, meme
--  anti-fuite, meme garde-fou GUC) avec des litteraux 100% ASCII : les
--  accents sont ecrits en echappements Unicode Postgres U&'...\00e9...',
--  inalterables par copier-coller. Aucune autre fonction touchee.
-- =====================================================================

create or replace function choisir_skin(
  p_matiere text, p_gravure text, p_aura text, p_mort text, p_teinte text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception U&'Non authentifi\00e9'; end if;

  -- Anti-fuite : jamais d'atelier en pleine partie (statut hors lobby/terminee)
  if exists (
    select 1 from joueurs_partie jp
      join parties p on p.id = jp.partie_id
     where jp.user_id = v_user
       and p.statut not in ('lobby', 'terminee')
  ) then
    raise exception U&'Impossible de changer d\0027apparence en pleine partie';
  end if;

  if not skin_debloque(v_user, 'matiere', p_matiere) then raise exception U&'Mati\00e8re verrouill\00e9e'; end if;
  if not skin_debloque(v_user, 'gravure', p_gravure) then raise exception U&'Gravure verrouill\00e9e'; end if;
  if not skin_debloque(v_user, 'aura',    p_aura)    then raise exception U&'Aura verrouill\00e9e';    end if;
  if not skin_debloque(v_user, 'mort',    p_mort)    then raise exception U&'Effet de mort verrouill\00e9'; end if;
  if not skin_debloque(v_user, 'teinte',  p_teinte)  then raise exception U&'Teinte verrouill\00e9e';  end if;

  -- Laissez-passer pour le garde-fou trigger (GUC local, reinitialise en fin de tx)
  perform set_config('loup_garou.skin_ok', '1', true);

  update profils set
    skin_matiere = p_matiere,
    skin_gravure = p_gravure,
    skin_aura    = p_aura,
    skin_mort    = p_mort,
    skin_teinte  = p_teinte
  where id = v_user;
end $$;

grant execute on function choisir_skin(text, text, text, text, text) to authenticated, service_role;
