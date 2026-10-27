-- Comando do medico pelo celular: "#ia" sinaliza que o contato e paciente e
-- a IA assume a conversa; "#off" tira a IA daquele contato de vez. Vale para
-- a conversa aberta e para as proximas do mesmo telefone.

create table if not exists public.wa_contato_ia (
  clinic_id  uuid not null references public.clinics(id) on delete cascade,
  fone_key   text not null,               -- nx_fone_key do telefone
  modo       text not null check (modo in ('paciente','off')),
  updated_at timestamptz not null default now(),
  primary key (clinic_id, fone_key)
);
alter table public.wa_contato_ia enable row level security;

-- Aplica o comando. Devolve a conversa (criada se nao houver uma aberta).
create or replace function public.nx_wa_comando_ia(p_phone_number_id text, p_to text, p_modo text)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_clinic uuid; v_conv uuid; v_paciente boolean := (p_modo = 'paciente');
begin
  select clinic_id into v_clinic from clinic_whatsapp where phone_number_id = p_phone_number_id;
  if v_clinic is null or nx_fone_key(p_to) is null then return null; end if;

  insert into wa_contato_ia(clinic_id, fone_key, modo)
    values (v_clinic, nx_fone_key(p_to), p_modo)
  on conflict (clinic_id, fone_key) do update set modo = excluded.modo, updated_at = now();

  select id into v_conv from conversations
   where clinic_id = v_clinic and nx_fone_key(telefone) = nx_fone_key(p_to)
     and status not in ('finalizada','resolvida')
   order by created_at desc limit 1;
  if v_conv is null then
    insert into conversations(clinic_id, telefone, canal, status, bot_active)
      values (v_clinic, p_to, 'WhatsApp', 'nova', v_paciente)
      returning id into v_conv;
  end if;

  update conversations set
    bot_active      = v_paciente,
    bot_state       = case when v_paciente then null else bot_state end,
    contexto_tipo   = case when v_paciente then 'paciente' else 'pessoal' end,
    contexto_motivo = case when v_paciente then 'sinalizado pelo médico (#ia)' else 'IA desligada pelo médico (#off)' end,
    updated_at      = now()
  where id = v_conv;
  return v_conv;
end $$;
revoke all on function public.nx_wa_comando_ia(text,text,text) from public, anon, authenticated;
grant execute on function public.nx_wa_comando_ia(text,text,text) to service_role;
