-- "#fim" mandado pelo medico no celular: encerra o atendimento daquela
-- conversa e guarda um resumo (data, motivo, risco, desfecho/orientacao) com
-- o PDF. Se a familia escrever de novo, comeca outro atendimento.

create table if not exists public.atendimento_resumo (
  id              uuid primary key default gen_random_uuid(),
  clinic_id       uuid not null references public.clinics(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  patient_id      uuid references public.patients(id) on delete set null,
  dados           jsonb not null,
  pdf_path        text,
  created_at      timestamptz not null default now()
);
create index if not exists atendimento_resumo_conv on public.atendimento_resumo(conversation_id);
alter table public.atendimento_resumo enable row level security;
drop policy if exists atendimento_resumo_membro on public.atendimento_resumo;
create policy atendimento_resumo_membro on public.atendimento_resumo for select
  using (public.is_member(clinic_id) or public.is_platform_admin());

-- Conversa aberta deste contato no numero da clinica.
create or replace function public.nx_wa_conv_aberta(p_phone_number_id text, p_to text)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select c.id from conversations c
    join clinic_whatsapp w on w.clinic_id = c.clinic_id and w.phone_number_id = p_phone_number_id
   where nx_fone_key(c.telefone) = nx_fone_key(p_to)
     and c.status not in ('finalizada','resolvida')
   order by c.created_at desc limit 1;
$$;
revoke all on function public.nx_wa_conv_aberta(text,text) from public, anon, authenticated;
grant execute on function public.nx_wa_conv_aberta(text,text) to service_role;
