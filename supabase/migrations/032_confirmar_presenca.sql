-- 032 - "CONFIRMAR" tem de confirmar a consulta.
-- A busca so olhava consulta no FUTURO (scheduled_at > now()). O lembrete de
-- confirmacao chega perto da hora - e as vezes depois dela, como no teste das
-- 12:15 para uma consulta das 12:00. Nao achando nada, a funcao devolvia
-- ok:false, o agente seguia para a proxima camada e a pessoa recebia a pergunta
-- de consentimento depois de responder CONFIRMAR. Fluxo quebrado na cara do
-- cliente.
-- Agora a janela cobre as ultimas 12h, a consulta DESTA conversa tem
-- preferencia, e quem ja confirmou recebe uma resposta clara.
-- ADITIVO.

create or replace function public.nx_appt_confirmar_paciente(p_conv uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cl uuid; tel text; patid uuid; aid uuid; q timestamptz; st text;
begin
  select clinic_id, telefone, patient_id into cl, tel, patid
    from public.conversations where id=p_conv;
  if cl is null then return jsonb_build_object('ok',false); end if;

  -- 1) a consulta desta conversa, ainda que tenha comecado ha pouco
  select id, scheduled_at, status into aid, q, st
    from public.appointments
   where conversation_id = p_conv
     and status in ('agendada','confirmada')
     and scheduled_at > now() - interval '12 hours'
   order by abs(extract(epoch from (scheduled_at - now())))
   limit 1;

  -- 2) senao, pelo paciente ou pelo telefone
  if aid is null then
    select id, scheduled_at, status into aid, q, st
      from public.appointments
     where clinic_id=cl and status in ('agendada','confirmada')
       and scheduled_at > now() - interval '12 hours'
       and (patient_id=patid
            or regexp_replace(coalesce(telefone,''),'\D','','g')=regexp_replace(coalesce(tel,''),'\D','','g'))
     order by abs(extract(epoch from (scheduled_at - now())))
     limit 1;
  end if;

  if aid is null then return jsonb_build_object('ok',false); end if;

  if st = 'confirmada' then
    return jsonb_build_object('ok',true,'ja_confirmada',true,
      'quando', to_char(q at time zone 'America/Sao_Paulo','DD/MM')||' às '||to_char(q at time zone 'America/Sao_Paulo','HH24:MI'));
  end if;

  update public.appointments set status='confirmada', confirmation_sent=true where id=aid;
  insert into public.appointment_events(appointment_id,clinic_id,tipo,por,motivo)
    values(aid,cl,'confirmado','paciente','confirmou presença pelo WhatsApp');

  return jsonb_build_object('ok',true,'ja_confirmada',false,
    'quando', to_char(q at time zone 'America/Sao_Paulo','DD/MM')||' às '||to_char(q at time zone 'America/Sao_Paulo','HH24:MI'));
end; $$;
