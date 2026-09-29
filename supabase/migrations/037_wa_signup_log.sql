-- Registro de cada tentativa de conexao do WhatsApp pelo cadastro da Meta.
-- A pagina grava o que a Meta devolve (mensagens do popup, retorno do login e
-- resposta da wa-signup), para diagnosticar pelo que a Meta respondeu e nao
-- por print de tela. Nao guarda o code de autorizacao, so se ele veio.

create table if not exists public.wa_signup_log (
  id          bigserial primary key,
  created_at  timestamptz not null default now(),
  user_id     uuid,
  clinic_id   uuid,
  tentativa   text,
  tipo        text not null,
  payload     jsonb,
  pagina      text,
  navegador   text
);
create index if not exists wa_signup_log_created on public.wa_signup_log (created_at desc);
alter table public.wa_signup_log enable row level security;

create or replace function public.nx_wa_signup_log(
  p_clinic uuid, p_tentativa text, p_tipo text, p_payload jsonb, p_pagina text, p_navegador text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then return; end if;
  if length(coalesce(p_payload::text,'')) > 20000 then
    p_payload := jsonb_build_object('truncado', left(p_payload::text, 20000));
  end if;
  insert into public.wa_signup_log(user_id, clinic_id, tentativa, tipo, payload, pagina, navegador)
  values (auth.uid(), p_clinic, left(p_tentativa,40), left(p_tipo,40), p_payload, left(p_pagina,300), left(p_navegador,300));
end; $$;

revoke all on function public.nx_wa_signup_log(uuid,text,text,jsonb,text,text) from public, anon;
grant execute on function public.nx_wa_signup_log(uuid,text,text,jsonb,text,text) to authenticated;
