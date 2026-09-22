-- 025 - Saber PARA QUEM e a consulta antes de agendar.
-- Quem chegava dizendo "quero agendar" pulava a identificacao: a agenda abria
-- sem nome, e o agendamento nascia sem paciente e sem prontuario. A secao 1 da
-- maquina de estados do cliente pede o contrario: identificar primeiro.
-- ADITIVO.

-- Pergunta de quem se trata, ja listando os filhos quando o telefone e conhecido.
create or replace function public.nx_book_pergunta_quem(p_conv uuid)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare quem jsonb; c jsonb; msg text; i int := 0;
begin
  quem := public.nx_conv_quem(p_conv);
  if not coalesce((quem->>'encontrado')::boolean,false)
     or jsonb_array_length(coalesce(quem->'criancas','[]'::jsonb)) = 0 then
    return 'Claro! Para quem e a consulta? Me diga o *nome* e a *idade* do paciente.';
  end if;
  msg := 'Claro'||coalesce(', '||(quem->>'responsavel_nome'),'')||'! Para quem e a consulta?';
  for c in select * from jsonb_array_elements(quem->'criancas') loop
    i := i + 1;
    msg := msg||chr(10)||i||') '||(c->>'nome');
  end loop;
  return msg||chr(10)||(i+1)||') Outra pessoa';
end; $$;

-- Le a resposta: numero da lista, nome digitado, ou "outra pessoa".
create or replace function public.nx_book_quem_step(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare quem jsonb; cr jsonb; qtd int; n int; nome text; idade text; m text[]; c jsonb;
begin
  quem := public.nx_conv_quem(p_conv);
  cr   := coalesce(quem->'criancas','[]'::jsonb);
  qtd  := jsonb_array_length(cr);
  n    := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;

  -- escolheu um dos ja cadastrados
  if qtd > 0 and n is not null and n between 1 and qtd
     and length(regexp_replace(coalesce(p_text,''),'\D','','g')) = 1 then
    nome := cr->(n-1)->>'nome';
    perform public.nx_conv_trocar_paciente(p_conv, nome);
    update public.conversations set bot_state=null where id=p_conv;
    return public.nx_book_start(p_conv);
  end if;

  -- "outra pessoa"
  if (qtd > 0 and n = qtd+1) or lower(coalesce(p_text,'')) ~ '(outra pessoa|outro|nenhum)' then
    update public.conversations set bot_ctx=coalesce(bot_ctx,'{}')||jsonb_build_object('quem_outro',true) where id=p_conv;
    return 'Sem problema. Me diga o *nome* e a *idade* do paciente, por favor.';
  end if;

  -- nome digitado (e idade, se vier junto)
  m := regexp_match(coalesce(p_text,''), '([0-9]{1,3})\s*(anos?|meses|m[eê]s)?');
  if m is not null then idade := m[1]; end if;
  nome := trim(regexp_replace(coalesce(p_text,''), '([0-9]{1,3})\s*(anos?|meses|m[eê]s)?', '', 'g'));
  nome := trim(both ' ,-' from regexp_replace(nome, '\s+', ' ', 'g'));
  -- tira o comeco de frase comum ("e para a ", "chama ")
  nome := regexp_replace(nome, '^(e |é |eh |para |pra |a |o |minha filha |meu filho |se chama |chama |nome )+', '', 'i');
  nome := trim(nome);

  if coalesce(nome,'') = '' or length(nome) < 2 then
    return 'Me diga o *nome* do paciente, por favor.';
  end if;

  perform public.nx_conv_trocar_paciente(p_conv, nome);
  if coalesce(idade,'') <> '' then
    update public.conversations set paciente_idade=idade where id=p_conv;
  end if;
  update public.conversations set bot_state=null where id=p_conv;
  return public.nx_book_start(p_conv);
end; $$;

-- nx_book_start: sem paciente identificado, pergunta antes de abrir a agenda.
create or replace function public.nx_book_start(p_conv uuid)
returns text language plpgsql security definer set search_path to 'public' as $$
declare prof uuid; cl uuid; nm text; mods jsonb; meds jsonb; pac text; st text;
begin
  select clinic_id, paciente_nome, bot_state into cl, pac, st from public.conversations where id=p_conv;

  -- 1) para quem e a consulta
  if coalesce(pac,'') = '' or lower(pac) in ('paciente','paciente whatsapp') then
    if coalesce(st,'') <> 'ag_quem' then
      update public.conversations set bot_state='ag_quem' where id=p_conv;
    end if;
    return public.nx_book_pergunta_quem(p_conv);
  end if;

  -- 2) com qual profissional
  prof := public.nx_conv_doctor(p_conv);
  if prof is null then
    meds := public.nx_book_medicos(cl);
    if jsonb_array_length(meds) = 0 then
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

-- Passos da agenda (o corpo que era o nx_book_step da 024).
create or replace function public.nx_book_step_agenda(p_conv uuid, p_text text)
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

-- nx_book_step: passo ag_quem entra antes de tudo.
create or replace function public.nx_book_step(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text;
begin
  select bot_state into st from public.conversations where id=p_conv;
  if st = 'ag_quem' then return public.nx_book_quem_step(p_conv, p_text); end if;
  return public.nx_book_step_agenda(p_conv, p_text);
end; $$;

revoke all on function public.nx_book_step_agenda(uuid,text) from public, anon, authenticated;
grant execute on function public.nx_book_step_agenda(uuid,text) to service_role;
revoke all on function public.nx_book_pergunta_quem(uuid) from public, anon, authenticated;
revoke all on function public.nx_book_quem_step(uuid,text) from public, anon, authenticated;
grant execute on function public.nx_book_pergunta_quem(uuid) to service_role;
grant execute on function public.nx_book_quem_step(uuid,text) to service_role;
