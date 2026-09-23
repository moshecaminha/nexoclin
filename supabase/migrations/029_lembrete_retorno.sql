-- 029 - Lembrete de retorno (secoes 6.8 e 9 do documento do cliente).
-- "Lembretes de vacina e retorno saem sozinhos, com os dados que o proprio
-- sistema controla." O de retorno passa a sair: quem consultou ha mais de N
-- dias e nao tem consulta marcada recebe o convite, uma vez, pelo template
-- ja aprovado (retorno_recomendado). Usa a mesma fila da 028, entao so conta
-- como enviado quando a Meta aceita.
-- ADITIVO.

-- Dias sem consulta que disparam o convite. A clinica pode mudar em
-- clinics.retorno_regra (so o numero de dias); o padrao e 180.
create or replace function public.nx_retorno_dias(p_clinic uuid)
returns int language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    nullif(regexp_replace(coalesce((select retorno_regra from public.clinics where id=p_clinic),''),'\D','','g'),'')::int,
    180);
$$;

create or replace function public.nx_wa_run_retornos()
returns integer language plpgsql security definer set search_path to 'public', 'net' as $$
declare r record; req bigint; sent int := 0; dias int; quanto text; conv uuid;
begin
  for r in
    select distinct on (a.clinic_id, a.telefone)
           a.clinic_id, a.telefone, a.paciente_nome, a.patient_id, a.profissional_nome,
           a.scheduled_at as ultima, w.phone_number_id, w.access_token, cl.nome as clinica
      from public.appointments a
      join public.clinic_whatsapp w on w.clinic_id=a.clinic_id and w.status='conectado'
      join public.clinics cl on cl.id=a.clinic_id and coalesce(cl.retorno_permite,true)
     where a.status='realizada' and coalesce(a.telefone,'')<>''
       and a.scheduled_at < now() - make_interval(days => public.nx_retorno_dias(a.clinic_id))
       -- nao tem consulta futura
       and not exists (select 1 from public.appointments f
                        where f.clinic_id=a.clinic_id and f.telefone=a.telefone
                          and f.scheduled_at > now() and f.status in ('agendada','confirmada'))
       -- nao foi convidado nos ultimos 90 dias
       and not exists (select 1 from public.wa_envio e
                        where e.clinic_id=a.clinic_id and e.telefone=a.telefone and e.tipo='retorno'
                          and e.created_at > now() - interval '90 days')
     order by a.clinic_id, a.telefone, a.scheduled_at desc
     limit 50
  loop
    dias := (extract(epoch from (now() - r.ultima))/86400)::int;
    quanto := case when dias >= 730 then (dias/365)::text||' anos'
                   when dias >= 365 then 'mais de um ano'
                   when dias >= 60  then (dias/30)::text||' meses'
                   else dias::text||' dias' end;

    select net.http_post(
      url := 'https://graph.facebook.com/v21.0/'||r.phone_number_id||'/messages',
      headers := jsonb_build_object('Authorization','Bearer '||r.access_token,'Content-Type','application/json'),
      body := jsonb_build_object('messaging_product','whatsapp','to',r.telefone,'type','template',
               'template', jsonb_build_object('name','retorno_recomendado','language',jsonb_build_object('code','pt_BR'),
                 'components', jsonb_build_array(jsonb_build_object('type','body','parameters',
                   jsonb_build_array(
                     jsonb_build_object('type','text','text',coalesce(r.paciente_nome,'paciente')),
                     jsonb_build_object('type','text','text',quanto),
                     jsonb_build_object('type','text','text',coalesce(r.profissional_nome,'a equipe')))))))
    ) into req;

    select id into conv from public.conversations
     where clinic_id=r.clinic_id and nx_fone_key(telefone)=nx_fone_key(r.telefone)
     order by created_at desc limit 1;

    insert into public.wa_envio(clinic_id, appointment_id, conversation_id, tipo, template, telefone, corpo, request_id)
      values (r.clinic_id, null, conv, 'retorno', 'retorno_recomendado', r.telefone,
              'Convite de retorno para '||coalesce(r.paciente_nome,'paciente')||' ('||quanto||' desde a ultima consulta).', req);
    sent := sent + 1;
  end loop;
  return sent;
end; $$;

revoke all on function public.nx_wa_run_retornos() from public, anon, authenticated;
grant execute on function public.nx_wa_run_retornos() to service_role;

-- Uma vez por dia, as 13h UTC (10h em Sao Paulo): convite de retorno nao e urgente.
select cron.schedule('wa-retornos', '0 13 * * *', 'select public.nx_wa_run_retornos();')
where not exists (select 1 from cron.job where jobname='wa-retornos');
