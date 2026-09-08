-- =====================================================================
-- Rede de recuperacao do agente.
-- O webhook responde 200 na hora e chama o agente em segundo plano
-- (EdgeRuntime.waitUntil). Se o isolate for reciclado antes do modelo
-- responder, o trabalho e descartado em silencio: a mensagem entra na
-- fila e o paciente fica sem resposta.
-- Esta funcao acha essas conversas para uma varredura reprocessar.
-- =====================================================================
create or replace function public.nx_wa_bot_pendentes()
returns table(conversation_id uuid, clinic_id uuid, telefone text, texto text)
language sql security definer set search_path to 'public' as $$
  with ultima as (
    select distinct on (m.conversation_id)
           m.conversation_id, m.direction, m.body, m.created_at
    from messages m
    order by m.conversation_id, m.created_at desc
  )
  select c.id, c.clinic_id, c.telefone, u.body
  from conversations c
  join ultima u on u.conversation_id = c.id
  where c.bot_active is true
    and c.status in ('nova','em_triagem')
    and u.direction = 'in'
    and coalesce(u.body,'') <> ''
    -- espera o caminho normal ter chance antes de reprocessar
    and u.created_at < now() - interval '45 seconds'
    -- nao ressuscita conversa velha
    and u.created_at > now() - interval '2 hours'
    and c.clinic_id is not null
    and exists (select 1 from clinic_whatsapp w
                 where w.clinic_id = c.clinic_id and w.status = 'conectado')
  order by u.created_at
  limit 20;
$$;

revoke all on function public.nx_wa_bot_pendentes() from public, anon, authenticated;
grant execute on function public.nx_wa_bot_pendentes() to service_role;
