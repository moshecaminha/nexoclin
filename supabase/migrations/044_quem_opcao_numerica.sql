-- Escolha do paciente no agendamento: o numero so vale como opcao ("1",
-- "2)") quando a mensagem e so o numero. "Maria 2 anos" era lido como
-- "2) Outra pessoa", e "Joao 1 ano" escolhia a primeira crianca da lista.
CREATE OR REPLACE FUNCTION public.nx_book_quem_step(p_conv uuid, p_text text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare quem jsonb; cr jsonb; qtd int; n int; nome text; idade text; m text[]; c jsonb;
begin
  quem := public.nx_conv_quem(p_conv);
  cr   := coalesce(quem->'criancas','[]'::jsonb);
  qtd  := jsonb_array_length(cr);
  n    := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;

  -- escolheu um dos ja cadastrados
  if qtd > 0 and n is not null and n between 1 and qtd
     and coalesce(p_text,'') ~ '^\s*[0-9]\s*[).]?\s*$' then
    nome := cr->(n-1)->>'nome';
    perform public.nx_conv_trocar_paciente(p_conv, nome);
    update public.conversations set bot_state=null where id=p_conv;
    return public.nx_book_start(p_conv);
  end if;

  -- "outra pessoa"
  if (qtd > 0 and n = qtd+1 and coalesce(p_text,'') ~ '^\s*[0-9]\s*[).]?\s*$') or lower(coalesce(p_text,'')) ~ '(outra pessoa|outro|nenhum)' then
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
end; $function$;
