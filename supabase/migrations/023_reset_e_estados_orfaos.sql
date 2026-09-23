-- 023 - Comando "zerar" e estados de agendamento orfaos.
-- 1) nx_dev_reset NUNCA EXISTIU no banco: o wa-webhook chamava, a RPC dava erro,
--    e o bot respondia "ja estava limpo". O comando de teste nunca funcionou.
-- 2) Conversas presas em bot_state antigo ('ag_dia','ag_slot','agenda_pref').
--    Esses passos sumiram quando o agendamento foi reescrito; a conversa ficava
--    num beco: "quero agendar" nao casava com o passo e caia no modelo, que
--    respondia "vou pedir para a equipe verificar os horarios".

-- Zera a conversa de um telefone (comando de teste pelo WhatsApp).
-- messages, collected_data e documents saem em cascata; appointments e notas
-- de prontuario apenas perdem o vinculo (o historico clinico nao e apagado).
create or replace function public.nx_dev_reset(p_telefone text, p_clinic uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare ids uuid[]; n_conv int := 0; n_msg int := 0;
begin
  select array_agg(id) into ids from public.conversations
   where public.nx_fone_key(telefone) = public.nx_fone_key(p_telefone)
     and (p_clinic is null or clinic_id = p_clinic);

  if ids is null or array_length(ids,1) is null then
    return jsonb_build_object('conversas_apagadas',0,'mensagens',0);
  end if;

  select count(*) into n_msg from public.messages where conversation_id = any(ids);
  delete from public.conversations where id = any(ids);
  get diagnostics n_conv = row_count;
  return jsonb_build_object('conversas_apagadas', n_conv, 'mensagens', n_msg);
end; $$;

-- Solta quem ficou preso no estado antigo: volta a ser conversa comum, e o
-- proximo "quero agendar" entra pelo fluxo novo.
update public.conversations
   set bot_state = null, updated_at = now()
 where bot_state in ('ag_dia','ag_slot','agenda_pref');

revoke all on function public.nx_dev_reset(text,uuid) from public, anon, authenticated;
grant execute on function public.nx_dev_reset(text,uuid) to service_role;
