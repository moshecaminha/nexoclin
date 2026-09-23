-- 024 - "Voce tem disponibilidade depois das 15h?"
-- No passo das opcoes, qualquer frase que nao fosse 1, 2 ou "outros" nao casava
-- com o passo: a camada determinista desistia, a conversa caia no modelo e
-- voltava a abertura com o consentimento - no meio do agendamento.
-- Agora o passo entende hora ("depois das 15h", "antes das 10", "as 16h") e
-- dia ("quinta", "23/09"), e nunca mais devolve a conversa para o inicio.
-- ADITIVO.

-- Horarios livres com filtro de hora e de dia.
create or replace function public.nx_agenda_slots_filtro(
  p_prof uuid, p_modalidade text, p_turno text, p_exclude jsonb,
  p_hora_min text default null, p_hora_max text default null, p_data date default null
) returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare res jsonb := '[]'::jsonb; d date; d0 date := (now() at time zone 'America/Sao_Paulo')::date;
        i int; dias int := 0; slots jsonb; hh text; ex text[];
begin
  select array(select jsonb_array_elements_text(coalesce(p_exclude,'[]'::jsonb))) into ex;
  for i in 0..21 loop
    d := d0 + i;
    if p_data is not null and d <> p_data then continue; end if;
    if p_data is null and to_char(d,'YYYY-MM-DD') = any(ex) then continue; end if;
    slots := public.nx_agenda_slots(p_prof, p_modalidade, d);
    hh := (select s from jsonb_array_elements_text(slots) s
             where ((p_turno='manha' and s < '12:00') or (p_turno='tarde' and s >= '12:00')
                    or (coalesce(p_turno,'') not in ('manha','tarde')))
               and (p_hora_min is null or s >= p_hora_min)
               and (p_hora_max is null or s <= p_hora_max)
             order by s limit 1);
    if hh is not null then
      res := res || jsonb_build_array(jsonb_build_object('data',to_char(d,'YYYY-MM-DD'),'dow',extract(dow from d),'hora',hh));
      dias := dias + 1; if dias >= 2 then exit; end if;
    end if;
  end loop;
  return res;
end; $$;

-- Le um pedido em texto livre: hora minima, hora maxima e dia.
create or replace function public.nx_book_pedido(p_text text)
returns jsonb language plpgsql immutable set search_path to 'public' as $$
declare t text := lower(coalesce(p_text,'')); h int; res jsonb := '{}'::jsonb; d date;
        d0 date := (now() at time zone 'America/Sao_Paulo')::date; dow int; m text[];
begin
  -- "depois das 15", "a partir das 15h", "apos as 15:00", "so de 15h em diante"
  m := regexp_match(t, '(?:depois|apos|ap[oó]s|a partir|partir)[^0-9]{0,12}([0-9]{1,2})');
  if m is not null then h := m[1]::int; res := res || jsonb_build_object('hora_min', lpad(h::text,2,'0')||':00'); end if;

  -- "antes das 10", "ate as 11h"
  m := regexp_match(t, '(?:antes|ate|at[eé])[^0-9]{0,12}([0-9]{1,2})');
  if m is not null then h := m[1]::int; res := res || jsonb_build_object('hora_max', lpad(h::text,2,'0')||':00'); end if;

  -- data explicita 23/09
  m := regexp_match(t, '([0-9]{1,2})/([0-9]{1,2})');
  if m is not null then
    begin
      d := make_date(extract(year from d0)::int, m[2]::int, m[1]::int);
      if d < d0 then d := d + interval '1 year'; end if;
      res := res || jsonb_build_object('data', to_char(d,'YYYY-MM-DD'));
    exception when others then null; end;
  end if;

  -- dia da semana / hoje / amanha
  if res->>'data' is null then
    dow := case
      when t ~ 'hoje' then extract(dow from d0)::int
      when t ~ 'amanh' then extract(dow from d0+1)::int
      when t ~ 'domingo' then 0 when t ~ 'segunda' then 1 when t ~ 'ter[cç]a' then 2
      when t ~ 'quarta' then 3 when t ~ 'quinta' then 4 when t ~ 'sexta' then 5
      when t ~ 's[aá]bado' then 6 else null end;
    if dow is not null then
      if t ~ 'hoje' then d := d0;
      elsif t ~ 'amanh' then d := d0 + 1;
      else
        d := d0;
        for h in 0..7 loop
          exit when extract(dow from d)::int = dow and d >= d0;
          d := d + 1;
        end loop;
        if d = d0 and extract(dow from d0)::int <> dow then d := d0 + 1; end if;
      end if;
      res := res || jsonb_build_object('data', to_char(d,'YYYY-MM-DD'));
    end if;
  end if;

  -- turno dito em texto
  if t ~ '(manh|cedo)' then res := res || jsonb_build_object('turno','manha');
  elsif t ~ '(tarde|noite)' then res := res || jsonb_build_object('turno','tarde'); end if;

  return res;
end; $$;

-- Monta a lista de opcoes (texto) e guarda no contexto da conversa.
create or replace function public.nx_book_ofertar(p_conv uuid, p_reset_shown boolean default false)
returns text language plpgsql security definer set search_path to 'public' as $$
declare ctx jsonb; prof uuid; nm text; offers jsonb; o jsonb; shown text[]; msg text; i int;
        modal text; turno text; hmin text; hmax text; alvo date;
begin
  select bot_ctx, professional_id into ctx, prof from public.conversations where id=p_conv;
  prof := coalesce(prof, public.nx_conv_doctor(p_conv));
  modal := coalesce(ctx->>'modalidade','presencial');
  turno := ctx->>'turno';
  hmin  := ctx->>'hora_min';
  hmax  := ctx->>'hora_max';
  alvo  := nullif(ctx->>'data','')::date;

  offers := public.nx_agenda_slots_filtro(prof, modal, turno,
              case when p_reset_shown then '[]'::jsonb else coalesce(ctx->'shown','[]'::jsonb) end,
              hmin, hmax, alvo);

  if jsonb_array_length(offers)=0 then
    -- pedido apertado demais: afrouxa e avisa
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, hmin, null, null);
    if jsonb_array_length(offers)=0 then
      offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, null, null, null);
      if jsonb_array_length(offers)=0 then return null; end if;
      msg := 'Nao achei vaga nesse horario nos proximos dias. O mais proximo que tenho e:';
    else
      msg := 'Nesse dia nao tenho vaga nesse horario. O mais proximo depois do horario que voce pediu e:';
    end if;
  else
    msg := 'Consegui estas opcoes:';
  end if;

  select nome into nm from public.profiles where id=prof;
  msg := replace(msg,'Consegui estas opcoes:','Consegui estas opcoes com '||coalesce(nm,'o profissional')||':');
  shown := array(select jsonb_array_elements_text(coalesce(ctx->'shown','[]'::jsonb)));
  i := 0;
  for o in select * from jsonb_array_elements(offers) loop i:=i+1;
    msg := msg||chr(10)||i||') '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora');
    shown := shown || (o->>'data');
  end loop;
  msg := msg||chr(10)||chr(10)||'Qual fica melhor? Responda *1* ou *2* - ou me diga o dia e a hora que voce prefere.';

  update public.conversations set
    bot_ctx = coalesce(ctx,'{}') || jsonb_build_object('offers',offers,'shown',to_jsonb(shown)),
    bot_state = 'ag_offer'
  where id=p_conv;
  return msg;
end; $$;

create or replace function public.nx_book_step(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; n int; aid uuid; sched timestamptz; msg text;
        meds jsonb; m jsonb; qtd int; ped jsonb;
begin
  select bot_state,bot_ctx,clinic_id,telefone,paciente_nome,patient_id into st,ctx,cl,tel,nm,patid
    from public.conversations where id=p_conv;
  prof := public.nx_conv_doctor(p_conv);
  if st='agenda_pref' then st:='ag_prof'; end if;

  if st='ag_prof' then
    meds := public.nx_book_medicos(cl);
    qtd := jsonb_array_length(meds);
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;
    if (n is not null and n = qtd+1)
       or lower(coalesce(p_text,'')) ~ '(tanto faz|qualquer|indiferente|mais cedo|mais pr[oó]xim|voc[eê] escolhe|n[aã]o tenho prefer)' then
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
    if prof is null then return public.nx_book_pergunta_prof(cl); end if;
    perform public.nx_conv_set_doctor(p_conv, prof);
    return public.nx_book_start(p_conv);

  elsif st='ag_mod' then
    if lower(p_text) ~ '(tele|v[ií]deo|online|2)' then modal:='telemedicina'; else modal:='presencial'; end if;
    update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal), bot_state='ag_turno' where id=p_conv;
    return 'Perfeito, '||modal||'. Voce prefere de *manha* ou a *tarde*?';

  elsif st='ag_turno' then
    ped := public.nx_book_pedido(p_text);
    turno := coalesce(ped->>'turno','qualquer');
    modal := coalesce(ctx->>'modalidade','presencial');
    if prof is null then
      prof := public.nx_book_prof_mais_cedo(cl, modal, turno);
      if prof is not null then perform public.nx_conv_set_doctor(p_conv, prof); end if;
    end if;
    if prof is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao encontrei horarios livres nos proximos dias. Vou pedir para a equipe te retornar com as melhores opcoes, tudo bem? 💙';
    end if;
    update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal,'turno',turno)||ped where id=p_conv;
    msg := public.nx_book_ofertar(p_conv, true);
    if msg is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao achei vaga nos proximos dias. Vou pedir para a equipe te retornar, tudo bem? 💙';
    end if;
    return msg;

  elsif st='ag_offer' then
    -- 1) escolheu uma das opcoes oferecidas
    offers := ctx->'offers';
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;
    if n is not null and n between 1 and coalesce(jsonb_array_length(offers),0)
       and length(regexp_replace(coalesce(p_text,''),'\D','','g')) = 1
       and coalesce(p_text,'') !~ '[hH]' then
      o := offers->(n-1);
      modal := coalesce(ctx->>'modalidade','presencial');
      sched := ((o->>'data')||' '||(o->>'hora')||':00')::timestamp at time zone 'America/Sao_Paulo';
      select nome into nm from public.profiles where id=prof;
      aid := public.nx_appt_create_bot(cl, patid, p_conv, (select paciente_nome from public.conversations where id=p_conv), tel, nm, prof, 'Consulta', sched, modal);
      update public.conversations set bot_state=null, status='agendada' where id=p_conv;
      if modal='telemedicina' then
        return 'Prontinho! Sua *teleconsulta* com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||'. Como e por video (pre-pago), vou te enviar o link de pagamento aqui em seguida. 💙';
      end if;
      return 'Prontinho! ✅ Sua consulta com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||' ('||modal||'). Voce vai receber lembretes por aqui. Se precisar remarcar, e so me avisar. 💙';
    end if;

    -- 2) pediu outras opcoes
    if lower(p_text) ~ '(outro|mais op|outra|diferente|nenhum)' and public.nx_book_pedido(p_text) = '{}'::jsonb then
      msg := public.nx_book_ofertar(p_conv, false);
      return coalesce(msg, 'Por ora nao tenho outros horarios. Quer que a equipe te retorne com mais opcoes?');
    end if;

    -- 3) pediu um horario ou dia especifico ("depois das 15h", "quinta")
    ped := public.nx_book_pedido(p_text);
    if ped <> '{}'::jsonb then
      update public.conversations set bot_ctx=coalesce(ctx,'{}')||ped where id=p_conv;
      msg := public.nx_book_ofertar(p_conv, true);
      return coalesce(msg, 'Nesse horario nao tenho vaga nos proximos dias. Quer tentar outro dia ou prefere que a equipe te retorne?');
    end if;

    -- 4) nao entendi: nunca devolve a conversa para o inicio
    return 'Me diga *1* ou *2*, ou o dia e a hora que voce prefere (por exemplo: "quinta de tarde" ou "depois das 15h").';
  end if;
  return null;
end; $$;

revoke all on function public.nx_agenda_slots_filtro(uuid,text,text,jsonb,text,text,date) from public, anon, authenticated;
revoke all on function public.nx_book_pedido(text) from public, anon, authenticated;
revoke all on function public.nx_book_ofertar(uuid,boolean) from public, anon, authenticated;
grant execute on function public.nx_agenda_slots_filtro(uuid,text,text,jsonb,text,text,date) to service_role;
grant execute on function public.nx_book_pedido(text) to service_role;
grant execute on function public.nx_book_ofertar(uuid,boolean) to service_role;
