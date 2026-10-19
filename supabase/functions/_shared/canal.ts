// supabase/functions/_shared/canal.ts
// Envio pelo canal da clinica: API oficial (Meta Cloud) ou uazapi (API nao
// oficial, pelo WhatsApp do celular). Quem chama nao precisa saber qual e.
//
// clinic_whatsapp, por provider:
//   meta_cloud: phone_number_id = id da Meta, access_token = token da Meta
//   uazapi:     phone_number_id = "uazapi:<numero>" (chave de roteamento),
//               access_token = token da instancia, api_url = servidor uazapi,
//               verify_token = segredo que vai na URL do webhook (?uaz=)

export type Conexao = {
  provider?: string | null;
  phone_number_id?: string | null;
  access_token?: string | null;
  api_url?: string | null;
};

export const CAMPOS_CONEXAO = "provider, phone_number_id, access_token, api_url";

const GRAPH = `https://graph.facebook.com/${Deno.env.get("WA_GRAPH_VERSION") ?? "v21.0"}`;

export const ehUazapi = (c?: Conexao | null) => c?.provider === "uazapi";

/** Chamada autenticada a instancia uazapi. */
export async function uazapi(c: Conexao, caminho: string, corpo?: unknown) {
  const base = String(c.api_url ?? "").replace(/\/+$/, "");
  const r = await fetch(base + caminho, {
    method: corpo === undefined ? "GET" : "POST",
    headers: { token: String(c.access_token ?? ""), "Content-Type": "application/json" },
    body: corpo === undefined ? undefined : JSON.stringify(corpo),
  });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body: j as any };
}

/** Envia texto. Devolve o id da mensagem para gravar, ou o erro do provedor. */
export async function enviarTextoCanal(c: Conexao, para: string, texto: string):
  Promise<{ ok: boolean; id: string | null; erro?: unknown }> {
  if (!c?.access_token) return { ok: false, id: null, erro: "sem token" };

  if (ehUazapi(c)) {
    const r = await uazapi(c, "/send/text", { number: String(para).replace(/\D/g, ""), text: texto });
    if (!r.ok || r.body?.error) return { ok: false, id: null, erro: r.body?.error ?? r.body };
    return { ok: true, id: r.body?.messageid ?? r.body?.id ?? null };
  }

  const r = await fetch(`${GRAPH}/${c.phone_number_id}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${c.access_token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", to: para, type: "text", text: { body: texto } }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) return { ok: false, id: null, erro: j?.error ?? j };
  return { ok: true, id: j?.messages?.[0]?.id ?? null };
}
