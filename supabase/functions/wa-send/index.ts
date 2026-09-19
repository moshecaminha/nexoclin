// supabase/functions/wa-send/index.ts
// Envio de mensagem pelo cockpit. Chamada pelo front COM o JWT do atendente.
// O token da clinica nunca chega ao navegador: quem le e esta funcao.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_SB  = Deno.env.get("SUPABASE_URL")!;
const SRV     = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON    = Deno.env.get("SUPABASE_ANON_KEY")!;
const GRAPH   = Deno.env.get("WA_GRAPH_VERSION") ?? "v21.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST")    return json({ erro: "method not allowed" }, 405);

  const jwt = req.headers.get("Authorization") ?? "";
  if (!jwt.startsWith("Bearer ")) return json({ erro: "sem autenticação" }, 401);

  let body: any;
  try { body = await req.json(); } catch { return json({ erro: "json inválido" }, 400); }
  // Aceita DOIS contratos, de proposito:
  //  (a) o nosso, centrado na conversa: { conversation_id, text | template }
  //  (b) o que ja estava documentado:   { clinic_id, to, kind, text | template }
  // Assim publicar esta versao nao quebra quem ja chamava a anterior.
  const conversation_id = body?.conversation_id ?? body?.conv_id ?? null;
  const text = body?.text ?? null;
  const template = body?.template ?? null;
  const clinic_direto = body?.clinic_id ?? null;
  const to_direto = body?.to ?? null;

  if (!conversation_id && !(clinic_direto && to_direto)) {
    return json({ erro: "informe conversation_id, ou clinic_id + to" }, 400);
  }
  if (!text && !template) return json({ erro: "informe text ou template" }, 400);

  // 1) Autoriza COMO O ATENDENTE. Se ele nao for da clinica, a RPC levanta excecao.
  const comoUsuario = createClient(URL_SB, ANON, {
    global: { headers: { Authorization: jwt } },
  });

  let ctx: any;
  if (conversation_id) {
    const { data, error } = await comoUsuario.rpc("nx_wa_can_send", { p_conv: conversation_id });
    if (error) return json({ erro: "sem permissão", detalhe: error.message }, 403);
    ctx = data;
  } else {
    // contrato (b): sem conversa, so clinica + destino
    const { data: pode, error } = await comoUsuario.rpc("nx_can_admin", { p_clinic: clinic_direto });
    if (error || pode !== true) return json({ erro: "sem permissão", detalhe: error?.message }, 403);
    const admin0 = createClient(URL_SB, SRV);
    const { data: conn0 } = await admin0.from("clinic_whatsapp")
      .select("phone_number_id").eq("clinic_id", clinic_direto).single();
    ctx = {
      clinic_id: clinic_direto, telefone: to_direto,
      phone_number_id: conn0?.phone_number_id, janela_aberta: !!template ? true : true,
    };
  }
  if (!ctx?.phone_number_id) return json({ erro: "clínica sem WhatsApp conectado" }, 409);

  // 2) Fora da janela de 24h a Meta so aceita template. Avisa em vez de falhar feio.
  if (text && !ctx.janela_aberta) {
    return json({
      erro: "janela_fechada",
      mensagem: "Passaram-se mais de 24h desde a última mensagem do paciente. Use um template aprovado.",
      ultima_entrada: ctx.ultima_entrada,
    }, 409);
  }

  // 3) Token da clinica: so aqui, com service_role.
  const admin = createClient(URL_SB, SRV);
  const { data: conn } = await admin
    .from("clinic_whatsapp").select("access_token, phone_number_id")
    .eq("clinic_id", ctx.clinic_id).single();
  if (!conn?.access_token) return json({ erro: "clínica sem token configurado" }, 409);

  // 4) Graph API
  const payload = text
    ? { messaging_product: "whatsapp", to: ctx.telefone, type: "text", text: { body: text } }
    : { messaging_product: "whatsapp", to: ctx.telefone, type: "template", template };

  const r = await fetch(`https://graph.facebook.com/${GRAPH}/${conn.phone_number_id}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${conn.access_token}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const resp = await r.json().catch(() => ({}));

  if (!r.ok) {
    // O erro da Meta e a informacao mais util que existe aqui. Devolve inteiro.
    return json({ erro: "meta_recusou", status: r.status, meta: resp?.error ?? resp }, 502);
  }

  // 5) Grava com o wamid, para o status (entregue/lido/falhou) achar a mensagem depois.
  const wamid = resp?.messages?.[0]?.id ?? null;
  if (!conversation_id) return json({ ok: true, wamid });   // contrato (b): nada a gravar
  const { data: msgId } = await admin.rpc("nx_wa_record_out", {
    p_conv: conversation_id,
    p_body: text ?? `[template ${template?.name ?? ""}]`,
    p_wamid: wamid,
    p_type: "text",
  });

  // 6) Intervencao humana pausa a IA. Excecao: mensagem do sistema, como o
  //    encaminhamento para agendamento, que religa a IA de proposito.
  if (body?.sistema !== true) {
    await admin.from("conversations")
      .update({ bot_active: false, updated_at: new Date().toISOString() })
      .eq("id", conversation_id);
  }

  return json({ ok: true, wamid, message_id: msgId });
});
