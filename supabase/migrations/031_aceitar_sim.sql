-- 031 - "Sim. Pode ser" tem de confirmar.
-- Com UMA opcao na mesa, a pessoa responde "sim", "pode ser", "serve", "isso",
-- "fechado" - e a camada deterministica exigia o numero 1. A conversa ficava
-- com cara de robo teimoso, repetindo a mesma instrucao.
-- Agora: com uma opcao, qualquer confirmacao fecha o agendamento; com duas,
-- ela pergunta QUAL, em vez de recitar a regra. Tambem entende "a primeira",
-- "a segunda", "a de quarta" e "o outro horario".
-- ADITIVO.

create or replace function public.nx_book_escolha(p_text text, p_qtd int)
returns int language plpgsql immutable set search_path to 'public' as $$
declare t text := lower(btrim(coalesce(p_text,'')));
begin
  if p_qtd is null or p_qtd < 1 then return null; end if;

  -- numero cru: "1", "2)", "opcao 2"
  if t ~ '^\s*(op[cç][aã]o\s*)?[0-9]\s*[).]?\s*$' then
    return nullif(regexp_replace(t,'\D','','g'),'')::int;
  end if;

  -- Ordinal por extenso. Exige o artigo ("a primeira") ou a palavra opcao,
  -- senao "segunda" seria lido como opcao 2 quando a pessoa quis segunda-feira.
  if t ~ '^(quero |prefiro |fico com |pode ser )?(a |na )?(primeira|1[aª°º])( op[cç][aã]o)?[.!]?$'
     or t ~ '^(a )?primeira op[cç][aã]o[.!]?$' then return 1; end if;
  if t ~ '^(quero |prefiro |fico com |pode ser )?(a |na )(segunda|2[aª°º])( op[cç][aã]o)?[.!]?$'
     or t ~ '^(a )?segunda op[cç][aã]o[.!]?$' then return 2; end if;

  -- confirmacao simples: so vale quando nao ha duvida (uma opcao)
  if p_qtd = 1 and t ~ '(^|\s)(sim|isso|isso mesmo|pode ser|pode|serve|fechado|fechou|confirmo|confirmar|perfeito|otimo|[oó]timo|beleza|blz|ok|okay|ta bom|t[aá] bom|tudo bem|claro|vamos|bora|quero|aceito|combinado|esse|essa|esse mesmo|essa mesma)(\s|$|[.!])' then
    return 1;
  end if;

  return null;
end; $$;

create or replace function public.nx_book_step_agenda(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; n int; aid uuid; sched timestamptz; msg text;
        meds jsonb; m jsonb; qtd int; ped jsonb; esc int;
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
    qtd := coalesce(jsonb_array_length(offers),0);
    ped := public.nx_book_pedido(p_text);
    esc := public.nx_book_escolha(p_text, qtd);

    -- escolha de opcao vem antes: "a segunda" e opcao 2, nao segunda-feira
    if esc is null and ped <> '{}'::jsonb then
      update public.conversations set
        bot_ctx = (coalesce(ctx,'{}') - 'hora' - 'hora_min' - 'hora_max' - 'data' - 'turno' - 'shown') || ped
       where id=p_conv;
      msg := public.nx_book_ofertar(p_conv, true);
      return coalesce(msg, 'Nao tenho vaga nesse horario nos proximos dias. Quer que a equipe te retorne?');
    end if;

    if esc is not null and esc between 1 and qtd then
      o := offers->(esc-1);
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

    if lower(p_text) ~ '(outro|mais op|outra|diferente|nenhum)' then
      msg := public.nx_book_ofertar(p_conv, false);
      return coalesce(msg, 'Por ora nao tenho outros horarios. Quer que a equipe te retorne com mais opcoes?');
    end if;

    -- disse sim mas ha mais de uma opcao: pergunta qual, sem recitar regra
    if qtd > 1 and lower(coalesce(p_text,'')) ~ '(sim|pode|serve|ok|beleza|fechado|isso|claro|quero)' then
      return 'Qual das duas? A de '||public.nx_dia_nome((offers->0->>'dow')::int)||' as '||(offers->0->>'hora')||
             ' ou a de '||public.nx_dia_nome((offers->1->>'dow')::int)||' as '||(offers->1->>'hora')||'?';
    end if;

    if qtd = 1 then
      return 'Desculpe, nao entendi. Confirmo '||public.nx_dia_nome((offers->0->>'dow')::int)||' '||
             to_char((offers->0->>'data')::date,'DD/MM')||' as '||(offers->0->>'hora')||
             '? Responda *sim* - ou me diga outro dia e horario.';
    end if;
    return 'Desculpe, nao entendi. Me diga *1* ou *2*, ou outro dia e horario (por exemplo: "quinta as 15h").';
  end if;
  return null;
end; $$;

revoke all on function public.nx_book_escolha(text,int) from public, anon, authenticated;
grant execute on function public.nx_book_escolha(text,int) to service_role;
