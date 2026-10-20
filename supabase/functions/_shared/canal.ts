// supabase/functions/_shared/canal.ts
// Envio pelo canal da clinica: API oficial pela Zernio, API oficial direto na
// Meta (legado) ou uazapi (API nao oficial, pelo WhatsApp do celular). Quem
// chama nao precisa saber qual e.
//
// clinic_whatsapp, por provider:
//   zernio:     phone_number_id = "zernio:<accountId>" (chave de roteamento),
//               access_token = accountId da Zernio. A API key e uma so, da
//               NexoClin, e fica no secret ZERNIO_API_KEY.
//   meta_cloud: phone_number_id = id da Meta, access_token = token da Meta
//   uazapi:     phone_number_id = "uazapi:<numero>" (chave de roteamento),
//               access_token = token da instancia, api_url = servidor uazapi,
//               verify_token = segredo que vai na URL do webhook (?uaz=)
import { createClient } from "npm:@supabase/supabase-js@2";

export type Conexao = {
  provider?: string | null;
  phone_number_id?: string | null;
  access_token?: string | null;
  api_url?: string | null;
};

export const CAMPOS_CONEXAO = "provider, phone_number_id, access_token, api_url";

const GRAPH = `https://graph.facebook.com/${Deno.env.get("WA_GRAPH_VERSION") ?? "v21.0"}`;
export const ZERNIO_API = "https://zernio.com/api/v1";

export const ehUazapi = (c?: Conexao | null) => c?.provider === "uazapi";
export const ehZernio = (c?: Conexao | null) => c?.provider === "zernio";

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

/** Chamada autenticada a API da Zernio. */
export async function zernio(caminho: string, corpo?: unknown, metodo?: string) {
  const r = await fetch(ZERNIO_API + caminho, {
    method: metodo ?? (corpo === undefined ? "GET" : "POST"),
    headers: {
      Authorization: `Bearer ${Deno.env.get("ZERNIO_API_KEY") ?? ""}`,
      "Content-Type": "application/json",
    },
    body: corpo === undefined ? undefined : JSON.stringify(corpo),
  });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body: j as any };
}

/** DDD + 8 ultimos digitos: casa o numero com ou sem 55 e com ou sem o 9. */
export function chaveFone(n: string): string {
  let d = String(n).replace(/\D/g, "");
  if (d.length > 11 && d.startsWith("55")) d = d.slice(2);
  return d.slice(0, 2) + d.slice(-8);
}

// deno-lint-ignore no-explicit-any
let sbCanal: any = null;
const sbc = () => sbCanal ??= createClient(
  Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

/** Guarda o id da conversa na Zernio: texto livre so sai por ele. */
export async function lembrarConversaZernio(conta: string, fone: string, convZernio: string) {
  if (!conta || !fone || !convZernio) return;
  const { error } = await sbc().from("wa_zernio_conversa").upsert({
    account_id: conta, fone_key: chaveFone(fone), telefone: String(fone).replace(/\D/g, ""),
    zernio_conversation_id: convZernio, updated_at: new Date().toISOString(),
  }, { onConflict: "account_id,fone_key" });
  if (error) console.error("wa_zernio_conversa:", error.message);
}

/**
 * Id da conversa na Zernio para este telefone. Normalmente ja veio no webhook
 * da ultima mensagem do paciente; se nao veio, procura na Zernio pelo numero.
 */
async function conversaZernio(conta: string, fone: string): Promise<string | null> {
  const { data } = await sbc().from("wa_zernio_conversa").select("zernio_conversation_id")
    .eq("account_id", conta).eq("fone_key", chaveFone(fone)).maybeSingle();
  if (data?.zernio_conversation_id) return data.zernio_conversation_id as string;

  // A busca casa o numero por trecho: os 8 ultimos digitos pegam o numero com
  // e sem o 9. Cada item vem como { conversation: { id, participantUsername } }.
  const digitos = String(fone).replace(/\D/g, "");
  const q = new URLSearchParams({ accountId: conta, platform: "whatsapp", query: digitos.slice(-8), limit: "20" });
  const r = await zernio(`/inbox/conversations/search?${q}`);
  const achada = ((r.body?.data ?? []) as any[]).map((d) => d?.conversation ?? d)
    .find((c) => [c?.participantUsername, c?.participantId, c?.id]
      .some((x) => x && chaveFone(String(x)) === chaveFone(digitos)));
  const id = achada?.id ?? null;
  if (id) await lembrarConversaZernio(conta, digitos, id);
  return id;
}

export type FalaHistorico = { quem: "contato" | "dono"; texto: string; em: string };

/**
 * Historico da conversa no proprio WhatsApp (coexistencia): o que o contato e
 * o dono do numero conversaram antes, inclusive pelo celular. Mais antigo
 * primeiro. Vazio se a Zernio nao tiver nada.
 */
export async function historicoZernio(conta: string, fone: string, n = 30): Promise<FalaHistorico[]> {
  const conv = await conversaZernio(conta, fone);
  if (!conv) return [];
  const q = new URLSearchParams({ accountId: conta, limit: String(n), sortOrder: "desc" });
  const r = await zernio(`/inbox/conversations/${encodeURIComponent(conv)}/messages?${q}`);
  return ((r.body?.messages ?? []) as any[]).reverse().map((m) => {
    const anexo = m?.attachments?.[0]?.type;
    const texto = String(m?.message ?? "").trim() || (anexo ? `[${anexo}]` : "");
    return {
      quem: m?.direction === "outgoing" ? "dono" : "contato",
      texto: texto.slice(0, 400),
      em: String(m?.createdAt ?? m?.sentAt ?? ""),
    } as FalaHistorico;
  }).filter((f) => f.texto);
}

/** Envia texto. Devolve o id da mensagem para gravar, ou o erro do provedor. */
export async function enviarTextoCanal(c: Conexao, para: string, texto: string):
  Promise<{ ok: boolean; id: string | null; erro?: unknown }> {
  if (!c?.access_token) return { ok: false, id: null, erro: "sem token" };

  if (ehZernio(c)) {
    const conta = String(c.access_token);
    const conv = await conversaZernio(conta, para);
    if (!conv) return { ok: false, id: null, erro: "conversa não encontrada na Zernio (o paciente precisa ter escrito antes)" };
    const r = await zernio(`/inbox/conversations/${encodeURIComponent(conv)}/messages`,
      { accountId: conta, message: texto });
    if (!r.ok || r.body?.success === false) return { ok: false, id: null, erro: r.body?.error ?? r.body };
    return { ok: true, id: r.body?.data?.messageId ?? null };
  }

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

/**
 * Template aprovado pela Zernio, no formato da Meta ({ name, language, components }).
 * POST /inbox/conversations abre a conversa ou reaproveita a que ja existe.
 */
export async function enviarTemplateZernio(c: Conexao, para: string, template: any):
  Promise<{ ok: boolean; id: string | null; erro?: unknown }> {
  const conta = String(c.access_token ?? "");
  const params: string[] = [];
  for (const comp of template?.components ?? []) {
    if (String(comp?.type ?? "").toLowerCase() !== "body") continue;
    for (const p of comp?.parameters ?? []) params.push(String(p?.text ?? ""));
  }
  const lingua = typeof template?.language === "string" ? template.language : (template?.language?.code ?? "pt_BR");
  const r = await zernio("/inbox/conversations", {
    accountId: conta, participantId: String(para).replace(/\D/g, ""),
    templateName: template?.name, templateLanguage: lingua, templateParams: params,
  });
  if (!r.ok || r.body?.success === false) return { ok: false, id: null, erro: r.body?.error ?? r.body };
  if (r.body?.data?.conversationId) await lembrarConversaZernio(conta, para, r.body.data.conversationId);
  return { ok: true, id: r.body?.data?.messageId ?? null };
}
