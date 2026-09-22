-- 019 - Agendamento com varios medicos.
-- Problema: nx_conv_doctor so resolve quando a clinica tem 1 medico. Com 2 ou mais
-- devolvia null e o nx_book_start caia em "vou encaminhar para a equipe organizar",
-- sem nunca consultar a agenda. Agora a IA pergunta o profissional e SEMPRE oferece
-- horarios reais.
-- ADITIVO: nenhuma funcao existente e apagada; nx_book_start/step sao substituidas.

-- 1) Medicos agendaveis da clinica (tem escala ativa cadastrada)
create or replace function public.nx_book_medicos(p_clinic uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'nome',x.nome) order by x.nome),'[]'::jsonb)
  from (
    select distinct pr.id, coalesce(pr.nome,'Profissional') nome
    from public.memberships m
    join public.profiles pr on pr.id=m.user_id
    where m.clinic_id=p_clinic and m.ativo and m.role='medico'
      and exists (select 1 from public.availability av where av.professional_id=pr.id and av.ativo)
  ) x;
$$;

-- 2) Entre varios medicos, o que tem a vaga mais proxima no turno pedido.
create or replace function public.nx_book_prof_mais_cedo(
  p_clinic uuid, p_modalidade text, p_turno text
) returns uuid language plpgsql stable security definer set search_path to 'public' as $$
declare m jsonb; melhor uuid; melhor_q text; s jsonb; quando text;
begin
  for m in select * from jsonb_array_elements(public.nx_book_medicos(p_clinic)) loop
    s := public.nx_agenda_slots_scarce((m->>'id')::uuid, p_modalidade, p_turno, '[]'::jsonb);
    if jsonb_array_length(s) > 0 then
      quando := (s->0->>'data')||' '||(s->0->>'hora');
      if melhor_q is null or quando < melhor_q then melhor_q := quando; melhor := (m->>'id')::uuid; end if;
    end if;
  end loop;
  return melhor;
end; $$;

-- 3) Oferecer tambem o dia de hoje (antes comecava sempre amanha).
create or replace function public.nx_agenda_slots_scarce(
  p_prof uuid, p_modalidade text, p_turno text, p_exclude jsonb
) returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare res jsonb := '[]'::jsonb; d date; d0 date := (now() at time zone 'America/Sao_Paulo')::date;
        i int; dias int := 0; slots jsonb; hh text; ex text[];
begin
  select array(select jsonb_array_elements_text(coalesce(p_exclude,'[]'::jsonb))) into ex;
  for i in 0..21 loop
    d := d0 + i;
    if to_char(d,'YYYY-MM-DD') = any(ex) then continue; end if;
    slots := public.nx_agenda_slots(p_prof, p_modalidade, d);
    hh := (select s from jsonb_array_elements_text(slots) s
             where (p_turno='manha' and s < '12:00') or (p_turno='tarde' and s >= '12:00') or (p_turno not in ('manha','tarde'))
             order by s limit 1);
    if hh is not null then
      res := res || jsonb_build_array(jsonb_build_object('data',to_char(d,'YYYY-MM-DD'),'dow',extract(dow from d),'hora',hh));
      dias := dias + 1; if dias >= 2 then exit; end if;
    end if;
  end loop;
  return res;
end; $$;

-- 4) Texto da pergunta "com qual profissional?"
create or replace function public.nx_book_pergunta_prof(p_clinic uuid)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare meds jsonb; m jsonb; i int := 0; msg text;
begin
  meds := public.nx_book_medicos(p_clinic);
  msg := 'Com qual profissional voce prefere?';
  for m in select * from jsonb_array_elements(meds) loop
    i := i + 1;
    msg := msg||chr(10)||i||') '||(m->>'nome');
  end loop;
  return msg||chr(10)||(i+1)||') Tanto faz, quero o horario mais proximo';
end; $$;

-- 5) Inicio do agendamento
create or replace function public.nx_book_start(p_conv uuid)
returns text language plpgsql security definer set search_path to 'public' as $$
declare prof uuid; cl uuid; nm text; mods jsonb; meds jsonb;
begin
  select clinic_id into cl from public.conversations where id=p_conv;
  prof := public.nx_conv_doctor(p_conv);

  if prof is null then
    meds := public.nx_book_medicos(cl);
    if jsonb_array_length(meds) = 0 then
      -- clinica sem escala cadastrada: unico caso em que a equipe assume
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Ainda nao tenho a agenda deste consultorio aberta por aqui. Vou pedir para a equipe te retornar com os horarios, tudo bem? 💙';
    elsif jsonb_array_length(meds) = 1 then
      prof := (meds->0->>'id')::uuid;
    else
      update public.conversations set bot_state='ag_prof', bot_ctx='{}'::jsonb where id=p_conv;
      return public.nx_book_pergunta_prof(cl);
    end if;
  end if;

  perform public.nx_conv_set_doctor(p_conv, prof);
  select nome into nm from public.profiles where id=prof;
  mods := public.nx_doc_modalidades(prof);
  if (mods->>'presencial')::boolean and (mods->>'telemedicina')::boolean then
    update public.conversations set bot_state='ag_mod', bot_ctx='{}'::jsonb where id=p_conv;
    return 'Vamos agendar com '||coalesce(nm,'o profissional')||'. Voce prefere *presencial* ou *telemedicina* (video)?';
  else
    update public.conversations set bot_state='ag_turno',
      bot_ctx=jsonb_build_object('modalidade', case when (mods->>'telemedicina')::boolean then 'telemedicina' else 'presencial' end)
     where id=p_conv;
    return 'Vamos agendar com '||coalesce(nm,'o profissional')||'. Voce prefere de *manha* ou a *tarde*?';
  end if;
end; $$;

-- 6) Passos da conversa de agendamento
create or replace function public.nx_book_step(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; shown text[]; n int; aid uuid; sched timestamptz; msg text; i int;
        meds jsonb; m jsonb; qtd int;
begin
  select bot_state,bot_ctx,clinic_id,telefone,paciente_nome,patient_id into st,ctx,cl,tel,nm,patid
    from public.conversations where id=p_conv;
  prof := public.nx_conv_doctor(p_conv);

  -- estado antigo (antes da 019): cai na escolha de profissional
  if st='agenda_pref' then st:='ag_prof'; end if;

  if st='ag_prof' then
    meds := public.nx_book_medicos(cl);
    qtd := jsonb_array_length(meds);
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;

    -- "tanto faz" / opcao qtd+1 / "mais cedo"
    if (n is not null and n = qtd+1)
       or lower(coalesce(p_text,'')) ~ '(tanto faz|qualquer|indiferente|mais cedo|mais pr[oó]xim|primeiro que|voc[eê] escolhe|nao tenho prefer|não tenho prefer)' then
      update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('sem_pref',true), bot_state='ag_turno' where id=p_conv;
      return 'Certo, vou buscar o horario mais proximo. Voce prefere de *manha* ou a *tarde*?';
    end if;

    if n is not null and n between 1 and qtd then
      prof := (meds->(n-1)->>'id')::uuid;
    else
      for m in select * from jsonb_array_elements(meds) loop
        if lower(coalesce(p_text,'')) like '%'||lower(m->>'nome')||'%'
           or lower(coalesce(p_text,'')) like '%'||lower(split_part(m->>'nome',' ',1))||'%' then
          prof := (m->>'id')::uuid; exit;
        end if;
      end loop;
    end if;

    if prof is null then
      return public.nx_book_pergunta_prof(cl);
    end if;
    perform public.nx_conv_set_doctor(p_conv, prof);
    return public.nx_book_start(p_conv);

  elsif st='ag_mod' then
    if lower(p_text) ~ '(tele|v[ií]deo|online|2)' then modal:='telemedicina'; else modal:='presencial'; end if;
    update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal), bot_state='ag_turno' where id=p_conv;
    return 'Perfeito, '||modal||'. Voce prefere de *manha* ou a *tarde*?';

  elsif st='ag_turno' then
    if lower(p_text) ~ '(manh|cedo)' then turno:='manha'; elsif lower(p_text) ~ 'tarde' then turno:='tarde'; else turno:='qualquer'; end if;
    modal := coalesce(ctx->>'modalidade','presencial');

    -- sem preferencia de profissional: escolhe o da vaga mais proxima
    if prof is null then
      prof := public.nx_book_prof_mais_cedo(cl, modal, turno);
      if prof is not null then perform public.nx_conv_set_doctor(p_conv, prof); end if;
    end if;
    if prof is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao encontrei horarios livres nesse turno nos proximos dias. Vou pedir para a equipe te retornar com as melhores opcoes, tudo bem? 💙';
    end if;

    offers := public.nx_agenda_slots_scarce(prof, modal, turno, '[]'::jsonb);
    if jsonb_array_length(offers)=0 then
      update public.conversations set bot_state='ag_turno' where id=p_conv;
      return 'Nesse turno nao achei vaga nos proximos dias. Quer tentar o outro turno? (responda *manha* ou *tarde*)';
    end if;
    select nome into nm from public.profiles where id=prof;
    msg := 'Consegui estas opcoes com '||coalesce(nm,'o profissional')||':'; i:=0; shown:=array[]::text[];
    for o in select * from jsonb_array_elements(offers) loop i:=i+1;
      msg := msg||chr(10)||i||') '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora');
      shown := shown || (o->>'data');
    end loop;
    msg := msg||chr(10)||chr(10)||'Qual fica melhor? Responda *1* ou *2* - ou digite *outros* para ver mais.';
    update public.conversations set
      bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal,'turno',turno,'offers',offers,'shown',to_jsonb(shown)),
      bot_state='ag_offer' where id=p_conv;
    return msg;

  elsif st='ag_offer' then
    modal := coalesce(ctx->>'modalidade','presencial'); turno := coalesce(ctx->>'turno','qualquer');
    if lower(p_text) ~ '(outro|mais|outra|diferente|nenhum)' then
      offers := public.nx_agenda_slots_scarce(prof, modal, turno, coalesce(ctx->'shown','[]'::jsonb));
      if jsonb_array_length(offers)=0 then
        return 'Por ora nao tenho outros horarios nesse turno. Quer que eu tente o outro turno, ou prefere que a equipe te retorne?';
      end if;
      shown := array(select jsonb_array_elements_text(coalesce(ctx->'shown','[]'::jsonb)));
      msg := 'Tambem tenho estas:'; i:=0;
      for o in select * from jsonb_array_elements(offers) loop i:=i+1;
        msg := msg||chr(10)||i||') '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora');
        shown := shown || (o->>'data');
      end loop;
      msg := msg||chr(10)||chr(10)||'Responda *1* ou *2*, ou *outros* para mais.';
      update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('offers',offers,'shown',to_jsonb(shown)), bot_state='ag_offer' where id=p_conv;
      return msg;
    end if;
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;
    offers := ctx->'offers';
    if n is null or n<1 or n>jsonb_array_length(offers) then
      return 'E so responder *1* ou *2* (ou *outros* para ver mais opcoes).';
    end if;
    o := offers->(n-1);
    sched := ((o->>'data')||' '||(o->>'hora')||':00')::timestamp at time zone 'America/Sao_Paulo';
    select nome into nm from public.profiles where id=prof;
    aid := public.nx_appt_create_bot(cl, patid, p_conv, (select paciente_nome from public.conversations where id=p_conv), tel, nm, prof, 'Consulta', sched, modal);
    update public.conversations set bot_state=null, status='agendada' where id=p_conv;
    if modal='telemedicina' then
      return 'Prontinho! Sua *teleconsulta* com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||'. Como e por video (pre-pago), vou te enviar o link de pagamento aqui em seguida. 💙';
    else
      return 'Prontinho! ✅ Sua consulta com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||' ('||modal||'). Voce vai receber lembretes por aqui. Se precisar remarcar, e so me avisar. 💙';
    end if;
  end if;
  return null;
end; $$;

revoke all on function public.nx_book_medicos(uuid) from public, anon, authenticated;
revoke all on function public.nx_book_prof_mais_cedo(uuid,text,text) from public, anon, authenticated;
revoke all on function public.nx_book_pergunta_prof(uuid) from public, anon, authenticated;
grant execute on function public.nx_book_medicos(uuid) to service_role;
grant execute on function public.nx_book_prof_mais_cedo(uuid,text,text) to service_role;
grant execute on function public.nx_book_pergunta_prof(uuid) to service_role;
