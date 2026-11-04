-- Lembretes e convites de retorno saem pelo numero de agendamento quando a
-- clinica tiver um (clinic_whatsapp_extra.lembretes); senao, pelo principal.

alter table public.clinic_whatsapp_extra add column if not exists lembretes boolean not null default false;
update public.clinic_whatsapp_extra set lembretes = true where rotulo ilike 'agend%' and not lembretes;

-- Numero que dispara os templates da clinica.
create or replace function public.nx_wa_numero_lembretes(p_clinic uuid)
returns table(provider text, phone_number_id text, access_token text)
language sql stable security definer set search_path to 'public' as $$
  select x.provider, x.phone_number_id, x.access_token from (
    select e.provider, e.phone_number_id, e.access_token, 1 as ordem
      from clinic_whatsapp_extra e
     where e.clinic_id = p_clinic and e.lembretes and e.status = 'conectado'
       and e.provider in ('meta_cloud','zernio')
    union all
    select coalesce(w.provider,'meta_cloud'), w.phone_number_id, w.access_token, 2
      from clinic_whatsapp w
     where w.clinic_id = p_clinic and w.status = 'conectado'
       and coalesce(w.provider,'meta_cloud') in ('meta_cloud','zernio')  -- uazapi nao tem template aprovado
  ) x order by ordem limit 1;
$$;
revoke all on function public.nx_wa_numero_lembretes(uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.nx_wa_run_reminders()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare r record; tmpl text; params jsonb; which text; sent int := 0;
        data_txt text; hora_txt text; req bigint; corpo text; conv uuid;
begin
  for r in
    select a.*, w.provider as w_provider, w.phone_number_id, w.access_token,
           coalesce(cl.rem_confirmacao,true) as rem_conf,
           coalesce(cl.rem_24h,true) as rem24, coalesce(cl.rem_2h,true) as rem2
    from public.appointments a
    join lateral public.nx_wa_numero_lembretes(a.clinic_id) w on true
    join public.clinics cl on cl.id=a.clinic_id
    where a.status in ('agendada','confirmada') and coalesce(a.telefone,'')<>''
      and (
        (a.confirmation_sent=false and coalesce(cl.rem_confirmacao,true))
        or (a.reminder_24h_sent=false and coalesce(cl.rem_24h,true) and a.scheduled_at <= now()+interval '24 hours' and a.scheduled_at > now()+interval '2 hours')
        or (a.reminder_2h_sent=false and coalesce(cl.rem_2h,true) and a.scheduled_at <= now()+interval '2 hours' and a.scheduled_at > now())
      )
    limit 50
  loop
    data_txt := to_char(r.scheduled_at at time zone 'America/Sao_Paulo','DD/MM');
    hora_txt := to_char(r.scheduled_at at time zone 'America/Sao_Paulo','HH24:MI');

    if r.confirmation_sent=false and r.rem_conf then
      which:='confirmation'; tmpl:='confirmacao_agendamento';
      params:=jsonb_build_array(coalesce(r.paciente_nome,'paciente'),coalesce(r.profissional_nome,'a equipe'),data_txt,hora_txt);
      corpo := 'Agendamento de '||coalesce(r.paciente_nome,'paciente')||' com '||coalesce(r.profissional_nome,'a equipe')||' em '||data_txt||' as '||hora_txt||'.';
    elsif r.reminder_24h_sent=false and r.rem24 and r.scheduled_at <= now()+interval '24 hours' and r.scheduled_at > now()+interval '2 hours' then
      which:='24h'; tmpl:='lembrete_consulta_24h';
      params:=jsonb_build_array(coalesce(r.paciente_nome,'paciente'),data_txt,hora_txt,coalesce(r.profissional_nome,'a equipe'));
      corpo := 'Lembrete: a consulta de '||coalesce(r.paciente_nome,'paciente')||' e amanha, '||data_txt||' as '||hora_txt||'.';
    elsif r.reminder_2h_sent=false and r.rem2 and r.scheduled_at <= now()+interval '2 hours' and r.scheduled_at > now() then
      which:='2h'; tmpl:='lembrete_consulta_2h';
      params:=jsonb_build_array(coalesce(r.paciente_nome,'paciente'),hora_txt);
      corpo := 'Lembrete: a consulta de '||coalesce(r.paciente_nome,'paciente')||' e hoje as '||hora_txt||'.';
    else
      continue;
    end if;

    -- ja existe disparo pendente deste tipo? nao duplica
    if exists (select 1 from public.wa_envio e
                where e.appointment_id=r.id and e.tipo=which and e.status='pendente') then
      continue;
    end if;

    req := public.nx_wa_template_post(coalesce(r.w_provider,'meta_cloud'), r.phone_number_id, r.access_token,
                                      r.telefone, tmpl, params);

    select id into conv from public.conversations
     where clinic_id=r.clinic_id and nx_fone_key(telefone)=nx_fone_key(r.telefone)
     order by created_at desc limit 1;

    insert into public.wa_envio(clinic_id, appointment_id, conversation_id, tipo, template, telefone, corpo, request_id,
                                tentativas)
      values (r.clinic_id, r.id, conv, which, tmpl, r.telefone, corpo, req,
              1 + (select count(*) from public.wa_envio e where e.appointment_id=r.id and e.tipo=which));
    sent := sent + 1;
  end loop;
  return sent;
end; $function$;

CREATE OR REPLACE FUNCTION public.nx_wa_run_retornos()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare r record; req bigint; sent int := 0; dias int; quanto text; conv uuid;
begin
  for r in
    select distinct on (a.clinic_id, a.telefone)
           a.clinic_id, a.telefone, a.paciente_nome, a.patient_id, a.profissional_nome,
           a.scheduled_at as ultima, w.provider as w_provider, w.phone_number_id, w.access_token, cl.nome as clinica
      from public.appointments a
      join lateral public.nx_wa_numero_lembretes(a.clinic_id) w on true
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

    req := public.nx_wa_template_post(coalesce(r.w_provider,'meta_cloud'), r.phone_number_id, r.access_token,
             r.telefone, 'retorno_recomendado',
             jsonb_build_array(coalesce(r.paciente_nome,'paciente'), quanto, coalesce(r.profissional_nome,'a equipe')));

    select id into conv from public.conversations
     where clinic_id=r.clinic_id and nx_fone_key(telefone)=nx_fone_key(r.telefone)
     order by created_at desc limit 1;

    insert into public.wa_envio(clinic_id, appointment_id, conversation_id, tipo, template, telefone, corpo, request_id)
      values (r.clinic_id, null, conv, 'retorno', 'retorno_recomendado', r.telefone,
              'Convite de retorno para '||coalesce(r.paciente_nome,'paciente')||' ('||quanto||' desde a ultima consulta).', req);
    sent := sent + 1;
  end loop;
  return sent;
end; $function$;
