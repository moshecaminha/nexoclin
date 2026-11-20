-- Regra do intervalo de consultas (pedido do Rafael) e lembretes automaticos.
--
-- Crianca cuja ultima consulta passou do intervalo recomendado para a idade
-- (guia da clinica: mensal ate 1 ano, 2 meses ate 18m, 3 meses ate 3-4 anos,
-- no maximo 6 meses depois) nao recebe orientacao pelo WhatsApp: a IA pausa o
-- pre-atendimento e oferece agendar ou falar com a secretaria.

alter table public.conversations
  add column if not exists bloqueio_em      timestamptz,  -- quando o pre-atendimento foi pausado
  add column if not exists lembretes_bloq   int not null default 0,
  add column if not exists lembrete_pre_em  timestamptz;  -- ultimo "gostaria de continuar?"

-- Folga (dias) antes de considerar o intervalo vencido. Por clinica.
alter table public.clinics add column if not exists intervalo_folga_dias int not null default 15;

-- Conversas que precisam de lembrete agora. Tudo dentro da janela de 24h do
-- WhatsApp (contada da ultima mensagem da familia) e so em horario comercial.
create or replace function public.nx_wa_lembretes_pendentes()
returns table(conversation_id uuid, clinic_id uuid, telefone text, tipo text, paciente text)
language sql stable security definer set search_path to 'public' as $$
  with base as (
    select c.id, c.clinic_id, c.telefone, c.status::text status, c.bot_state, c.bloqueio_em, c.lembretes_bloq,
           c.lembrete_pre_em, coalesce(c.paciente_nome, '') paciente,
           (select max(m.created_at) from messages m where m.conversation_id = c.id and m.direction = 'in') ult_in,
           (select m.created_at from messages m where m.conversation_id = c.id
             order by m.created_at desc limit 1) ult_msg,
           (select m.author from messages m where m.conversation_id = c.id
             order by m.created_at desc limit 1) ult_autor
      from conversations c
     where c.bot_active and c.status not in ('finalizada','resolvida')
       and c.updated_at > now() - interval '1 day'
  )
  select b.id, b.clinic_id, b.telefone,
         case when b.bot_state = 'bloq_intervalo' then 'bloqueio' else 'pre' end, b.paciente
    from base b
   where b.ult_in > now() - interval '23 hours'               -- ainda na janela de 24h
     and b.ult_autor = 'assistente'                             -- a IA falou por ultimo, familia sumiu
     and extract(hour from now() at time zone 'America/Sao_Paulo') between 8 and 20
     and (
       -- 1) pre-atendimento parado: um lembrete 2h30 depois da ultima fala da IA
       (b.bot_state is distinct from 'bloq_intervalo'
         and b.status in ('nova','em_triagem')                  -- triagem ainda em curso
         and b.ult_msg < now() - interval '150 minutes'
         and (b.lembrete_pre_em is null or b.lembrete_pre_em < b.ult_in))
       or
       -- 2) pausado pelo intervalo: lembrete em ~3h e ~20h, sem agendamento depois
       (b.bot_state = 'bloq_intervalo' and (
          (b.lembretes_bloq = 0 and b.bloqueio_em < now() - interval '3 hours') or
          (b.lembretes_bloq = 1 and b.bloqueio_em < now() - interval '20 hours')))
     )
   limit 20;
$$;
revoke all on function public.nx_wa_lembretes_pendentes() from public, anon, authenticated;
grant execute on function public.nx_wa_lembretes_pendentes() to service_role;
