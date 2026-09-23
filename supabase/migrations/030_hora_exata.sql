-- 030 - "As 15h pode ser?" e "Quarta, 15h".
-- A leitura do pedido so entendia FAIXA ("depois das 15h", "antes das 10").
-- Hora cravada nao casava com nada: "As 15h pode ser?" caia no "me diga 1 ou 2",
-- e "Quarta, 15h" pegava o dia mas ignorava a hora, reoferecendo 12:00.
-- Agora hora exata e entendida, e a oferta diz o que realmente tem: se o
-- horario pedido existe, oferece ele; se nao, diz que nao tem e mostra o mais
-- proximo. O texto tambem para de pedir "1 ou 2" quando so ha uma opcao.
-- ADITIVO.

create or replace function public.nx_book_pedido(p_text text)
returns jsonb language plpgsql immutable set search_path to 'public' as $$
declare t text := lower(coalesce(p_text,'')); h int; mi int; res jsonb := '{}'::jsonb; d date;
        d0 date := (now() at time zone 'America/Sao_Paulo')::date; dow int; m text[]; faixa boolean := false;
begin
  -- faixa: "depois das 15", "a partir das 15h", "apos as 15:00"
  m := regexp_match(t, '(?:depois|apos|ap[oó]s|a partir|partir)[^0-9]{0,12}([0-9]{1,2})');
  if m is not null then
    h := m[1]::int; faixa := true;
    res := res || jsonb_build_object('hora_min', lpad(h::text,2,'0')||':00');
  end if;

  -- faixa: "antes das 10", "ate as 11h"
  m := regexp_match(t, '(?:antes|ate|at[eé])[^0-9]{0,12}([0-9]{1,2})');
  if m is not null then
    h := m[1]::int; faixa := true;
    res := res || jsonb_build_object('hora_max', lpad(h::text,2,'0')||':00');
  end if;

  -- hora cravada: "as 15h", "às 15:30", "15h", "15:00" (so quando nao e faixa)
  if not faixa then
    m := regexp_match(t, '(?:^|[^0-9/])([0-9]{1,2})\s*(?::|h)\s*([0-9]{2})?');
    if m is not null then
      h := m[1]::int;
      mi := coalesce(m[2]::int, 0);
      if h between 0 and 23 and mi between 0 and 59 then
        res := res || jsonb_build_object('hora', lpad(h::text,2,'0')||':'||lpad(mi::text,2,'0'));
      end if;
    end if;
  end if;

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
          exit when extract(dow from d)::int = dow;
          d := d + 1;
        end loop;
      end if;
      res := res || jsonb_build_object('data', to_char(d,'YYYY-MM-DD'));
    end if;
  end if;

  if t ~ '(manh|cedo)' then res := res || jsonb_build_object('turno','manha');
  elsif t ~ '(tarde|noite)' then res := res || jsonb_build_object('turno','tarde'); end if;

  return res;
end; $$;

-- Horarios livres, agora tambem com hora cravada.
create or replace function public.nx_agenda_slots_filtro(
  p_prof uuid, p_modalidade text, p_turno text, p_exclude jsonb,
  p_hora_min text default null, p_hora_max text default null, p_data date default null,
  p_hora text default null
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

    if p_hora is not null then
      -- hora cravada: so serve o horario pedido
      hh := (select s from jsonb_array_elements_text(slots) s where s = p_hora limit 1);
    else
      hh := (select s from jsonb_array_elements_text(slots) s
               where ((p_turno='manha' and s < '12:00') or (p_turno='tarde' and s >= '12:00')
                      or (coalesce(p_turno,'') not in ('manha','tarde')))
                 and (p_hora_min is null or s >= p_hora_min)
                 and (p_hora_max is null or s <= p_hora_max)
               order by s limit 1);
    end if;

    if hh is not null then
      res := res || jsonb_build_array(jsonb_build_object('data',to_char(d,'YYYY-MM-DD'),'dow',extract(dow from d),'hora',hh));
      dias := dias + 1; if dias >= 2 then exit; end if;
    end if;
  end loop;
  return res;
end; $$;

create or replace function public.nx_book_ofertar(p_conv uuid, p_reset_shown boolean default false)
returns text language plpgsql security definer set search_path to 'public' as $$
declare ctx jsonb; prof uuid; nm text; offers jsonb; o jsonb; shown text[]; msg text; i int;
        modal text; turno text; hmin text; hmax text; hora text; alvo date; cabeca text; qtd int;
begin
  select bot_ctx, professional_id into ctx, prof from public.conversations where id=p_conv;
  prof := coalesce(prof, public.nx_conv_doctor(p_conv));
  modal := coalesce(ctx->>'modalidade','presencial');
  turno := ctx->>'turno';
  hmin  := ctx->>'hora_min';
  hmax  := ctx->>'hora_max';
  hora  := ctx->>'hora';
  alvo  := nullif(ctx->>'data','')::date;
  select nome into nm from public.profiles where id=prof;

  -- 1) exatamente o que a pessoa pediu
  offers := public.nx_agenda_slots_filtro(prof, modal, turno,
              case when p_reset_shown then '[]'::jsonb else coalesce(ctx->'shown','[]'::jsonb) end,
              hmin, hmax, alvo, hora);
  cabeca := 'Consegui estas opcoes com '||coalesce(nm,'o profissional')||':';

  -- 2) nao tem: afrouxa por etapas e AVISA que nao e o que foi pedido
  if jsonb_array_length(offers)=0 and hora is not null and alvo is not null then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, hora, null, alvo, null);
    if jsonb_array_length(offers) > 0 then
      cabeca := 'Nesse dia nao tenho '||hora||'. O mais proximo depois disso e:';
    end if;
  end if;
  if jsonb_array_length(offers)=0 and hora is not null then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, hora, null, null, null);
    if jsonb_array_length(offers) > 0 then
      cabeca := 'Nao tenho '||hora||coalesce(' em '||to_char(alvo,'DD/MM'),'')||'. O mais proximo e:';
    end if;
  end if;
  if jsonb_array_length(offers)=0 and (hmin is not null or hmax is not null or turno is not null) then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, hmin, null, null, null);
    if jsonb_array_length(offers) > 0 then
      cabeca := 'Nesse horario nao tenho vaga. O mais proximo e:';
    end if;
  end if;
  if jsonb_array_length(offers)=0 then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, null, null, null, null);
    if jsonb_array_length(offers)=0 then return null; end if;
    cabeca := 'Nao achei vaga no que voce pediu. O mais proximo que tenho e:';
  end if;

  qtd := jsonb_array_length(offers);
  shown := array(select jsonb_array_elements_text(coalesce(ctx->'shown','[]'::jsonb)));
  msg := cabeca; i := 0;
  for o in select * from jsonb_array_elements(offers) loop i:=i+1;
    msg := msg||chr(10)||i||') '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora');
    shown := shown || (o->>'data');
  end loop;
  msg := msg||chr(10)||chr(10)||
    case when qtd = 1
      then 'Serve? Responda *1* para confirmar - ou me diga outro dia e horario.'
      else 'Qual fica melhor? Responda *1* ou *2* - ou me diga o dia e a hora que voce prefere.' end;

  update public.conversations set
    bot_ctx = coalesce(ctx,'{}') || jsonb_build_object('offers',offers,'shown',to_jsonb(shown)),
    bot_state = 'ag_offer'
  where id=p_conv;
  return msg;
end; $$;

-- No passo das opcoes, "1" e escolha; "15h" e pedido de horario.
create or replace function public.nx_book_step_agenda(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; n int; aid uuid; sched timestamptz; msg text;
        meds jsonb; m jsonb; qtd int; ped jsonb; so_numero boolean;
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
    modal := coalesce(ctx->>'modalidade','presencial');
    turno := coalesce(ped->>'turno', case when ped ? 'hora' or ped ? 'hora_min' then null else 'qualquer' end);
    if prof is null then
      prof := public.nx_book_prof_mais_cedo(cl, modal, coalesce(turno,'qualquer'));
      if prof is not null then perform public.nx_conv_set_doctor(p_conv, prof); end if;
    end if;
    if prof is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao encontrei horarios livres nos proximos dias. Vou pedir para a equipe te retornar com as melhores opcoes, tudo bem? 💙';
    end if;
    update public.conversations set
      bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal)||ped
              ||case when turno is null then '{}'::jsonb else jsonb_build_object('turno',turno) end
     where id=p_conv;
    msg := public.nx_book_ofertar(p_conv, true);
    if msg is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao achei vaga nos proximos dias. Vou pedir para a equipe te retornar, tudo bem? 💙';
    end if;
    return msg;

  elsif st='ag_offer' then
    offers := ctx->'offers';
    ped := public.nx_book_pedido(p_text);
    -- "1" ou "2" sozinho e escolha; "15h", "quarta 15h", "23/09" e pedido
    so_numero := coalesce(p_text,'') ~ '^\s*[0-9]\s*[).]?\s*$';
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;

    if so_numero and n between 1 and coalesce(jsonb_array_length(offers),0) then
      o := offers->(n-1);
      modal := coalesce(ctx->>'modalidade','presencial');
      sched := ((o->>'data')||' '||(o->>'hora')||':00')::timestamp at time zone 'America/Sao_Paulo';
      select nome into nm from public.profiles where id=prof;
      aid := public.nx_appt_create_bot(cl, patid, p_conv, (select paciente_nome from public.conversations where id=p_conv), tel, nm, prof, 'Consulta', sched, modal);
      update public.conversations set bot_state=null, status='agendada' where id=p_conv;
      if modal='telemedicina' then
        return public.nx_book_confirmacao(aid, 'Prontinho! Sua *teleconsulta* com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||'. Como e por video, o pagamento e antecipado. 💙');
      end if;
      return public.nx_book_confirmacao(aid, 'Prontinho! ✅ Sua consulta com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||' ('||modal||'). Voce vai receber lembretes por aqui. Se precisar remarcar, e so me avisar. 💙');
    end if;

    if lower(p_text) ~ '(outro|mais op|outra|diferente|nenhum)' and ped = '{}'::jsonb then
      msg := public.nx_book_ofertar(p_conv, false);
      return coalesce(msg, 'Por ora nao tenho outros horarios. Quer que a equipe te retorne com mais opcoes?');
    end if;

    if ped <> '{}'::jsonb then
      -- pedido novo substitui o anterior (dia e hora), nao acumula
      update public.conversations set
        bot_ctx = (coalesce(ctx,'{}') - 'hora' - 'hora_min' - 'hora_max' - 'data' - 'turno' - 'shown') || ped
       where id=p_conv;
      msg := public.nx_book_ofertar(p_conv, true);
      return coalesce(msg, 'Nao tenho vaga nesse horario nos proximos dias. Quer que a equipe te retorne?');
    end if;

    return 'Me diga *1* ou *2*, ou o dia e a hora que voce prefere (por exemplo: "quarta as 15h" ou "depois das 15h").';
  end if;
  return null;
end; $$;

revoke all on function public.nx_agenda_slots_filtro(uuid,text,text,jsonb,text,text,date,text) from public, anon, authenticated;
grant execute on function public.nx_agenda_slots_filtro(uuid,text,text,jsonb,text,text,date,text) to service_role;
