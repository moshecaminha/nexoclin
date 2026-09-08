// supabase/functions/wa-sweep/index.ts
// Rede de recuperacao do agente.
//
// O webhook responde 200 na hora e chama o agente em segundo plano
// (EdgeRuntime.waitUntil), porque demorar faz a Meta reentregar tudo. O preco
// e que, se o isolate for reciclado antes do modelo responder, o trabalho some
// em silencio: a mensagem entra na fila e o paciente fica sem resposta.
//
// Esta funcao roda por cron, acha as conversas nessa situacao e responde.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_SB = Deno.env.get("SUPABASE_URL")!;
const sb = createClient(URL_SB, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const GRAPH = `https://graph.facebook.com/${Deno.env.get("WA_GRAPH_VERSION") ?? "v21.0"}`;
const INTERNO = Deno.env.get("WA_INTERNAL_SECRET") ?? "";

async function responder(conv: string, clinic: string, telefone: string, texto: string) {
  const r = await fetch(`${URL_SB}/functions/v1/wa-agent`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
      "x-nx-internal": INTERNO,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ conversation_id: conv, texto }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j?.resposta) return null;

  const { data: conn } = await sb.from("clinic_whatsapp")
    .select("access_token, phone_number_id").eq("clinic_id", clinic).single();
  if (!conn?.access_token) return null;

  const env = await fetch(`${GRAPH}/${conn.phone_number_id}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${conn.access_token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp", to: telefone, type: "text", text: { body: j.resposta },
    }),
  });
  const out = await env.json().catch(() => ({}));
  if (!env.ok) { console.error("sweep envio:", JSON.stringify(out?.error ?? out)); return null; }

  await sb.rpc("nx_wa_record_out", {
    p_conv: conv, p_body: j.resposta,
    p_wamid: out?.messages?.[0]?.id ?? null, p_type: "text", p_author: "assistente",
  });
  return j.resposta as string;
}

Deno.serve(async (req) => {
  if (INTERNO && req.headers.get("x-nx-internal") !== INTERNO) {
    return new Response("forbidden", { status: 403 });
  }
  try {
    const { data: pend } = await sb.rpc("nx_wa_bot_pendentes");
    const lista = (pend ?? []) as Array<{
      conversation_id: string; clinic_id: string; telefone: string; texto: string;
    }>;

    const feitas: string[] = [];
    for (const p of lista) {
      const r = await responder(p.conversation_id, p.clinic_id, p.telefone, p.texto);
      if (r) feitas.push(p.conversation_id);
    }
    return Response.json({ ok: true, pendentes: lista.length, respondidas: feitas.length });
  } catch (e) {
    console.error("wa-sweep:", e instanceof Error ? e.message : e);
    return Response.json({ erro: String(e) }, { status: 500 });
  }
});
