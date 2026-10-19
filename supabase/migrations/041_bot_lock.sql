-- Trava de resposta da IA por conversa. Sem ela, duas chamadas ao agente na
-- mesma conversa (mensagens entregues fora de ordem, reentrega do webhook ou
-- a wa-sweep junto com o webhook) respondiam em dobro.
create table if not exists public.wa_bot_lock (
  conversation_id uuid primary key references public.conversations(id) on delete cascade,
  ate             timestamptz not null
);
alter table public.wa_bot_lock enable row level security;

-- Pega a trava se estiver livre ou vencida. Vence sozinha: uma funcao que
-- morrer no meio nao deixa a conversa presa.
create or replace function public.nx_wa_bot_lock(p_conv uuid, p_seg int default 90)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare ok uuid;
begin
  insert into public.wa_bot_lock(conversation_id, ate)
    values (p_conv, now() + make_interval(secs => p_seg))
  on conflict (conversation_id) do update set ate = excluded.ate
    where public.wa_bot_lock.ate < now()
  returning conversation_id into ok;
  return ok is not null;
end $$;

create or replace function public.nx_wa_bot_unlock(p_conv uuid)
returns void language sql security definer set search_path to 'public' as $$
  delete from public.wa_bot_lock where conversation_id = p_conv;
$$;

revoke all on function public.nx_wa_bot_lock(uuid,int) from public, anon, authenticated;
revoke all on function public.nx_wa_bot_unlock(uuid) from public, anon, authenticated;
grant execute on function public.nx_wa_bot_lock(uuid,int) to service_role;
grant execute on function public.nx_wa_bot_unlock(uuid) to service_role;
