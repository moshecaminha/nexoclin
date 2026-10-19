-- Com a IA pausada na clinica, os numeros de clinic_whatsapp.numeros_permitidos
-- continuam sendo atendidos pela IA. Serve para testar no numero real sem
-- responder os contatos pessoais do medico.
create or replace function public.nx_ia_liberada(p_clinic uuid, p_telefone text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select not coalesce((select ia_pausada from public.clinics where id = p_clinic), false)
      or exists (select 1 from public.clinic_whatsapp w, unnest(coalesce(w.numeros_permitidos, '{}'::text[])) n
                  where w.clinic_id = p_clinic and public.nx_fone_key(n) = public.nx_fone_key(p_telefone));
$$;
revoke all on function public.nx_ia_liberada(uuid,text) from public, anon, authenticated;
grant execute on function public.nx_ia_liberada(uuid,text) to service_role;

create or replace function public.nx_trg_conv_ia_pausada() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.nx_ia_liberada(new.clinic_id, new.telefone) then
    new.bot_active := false;
  end if;
  return new;
end $$;
