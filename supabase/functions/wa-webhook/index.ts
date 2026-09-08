// supabase/functions/wa-webhook/index.ts
// Webhook unico da NexoClin para a WhatsApp Cloud API (app Tech Provider).
// Roteia por phone_number_id: a Meta entrega TODAS as WABAs nesta mesma URL.
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const enc = new TextEncoder();
const URL_SB = Deno.env.get("SUPABASE_URL")!;

/** HMAC-SHA256 do corpo cru, comparado em tempo constante. */
async function confere(raw: string, recebido: string, appSecret: string) {
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(appSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(raw));
  const esperado = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (esperado.length !== recebido.length) return false;
  let diff = 0;
  for (let i = 0; i < esperado.length; i++) diff |= esperado.charCodeAt(i) ^ recebido.charCodeAt(i);
  return diff === 0;
}

/**
 * Aceita mais de um app secret. Enquanto a NexoClin nao tiver Tech Provider
 * proprio, uma clinica pode estar conectada pelo app do MVF — e ai a Meta
 * assina com o secret DAQUELE app, nao com o desta.
 */
async function assinaturaValida(raw: string, header: string | null) {
  if (!header?.startsWith("sha256=")) return false;
  const recebido = header.slice(7);
  const segredos = [
    Deno.env.get("WA_APP_SECRET"),
    Deno.env.get("WA_APP_SECRET_MVF"),
  ].filter(Boolean) as string[];
  for (const s of segredos) {
    if (await confere(raw, recebido, s)) return true;
  }
  return false;
}

/** Texto exibivel de cada tipo de mensagem, para a fila nao ficar vazia. */
function corpoDe(msg: any): string | null {
  switch (msg.type) {
    case "text": return msg.text?.body ?? null;
    case "button": return msg.button?.text ?? null;
    case "interactive":
      return msg.interactive?.button_reply?.title ?? msg.interactive?.list_reply?.title ?? null;
    case "image": case "video": case "document": case "audio": case "sticker":
      return msg[msg.type]?.caption ?? null;
    case "location": return msg.location?.name ?? "[localizacao]";
    case "contacts": return "[contato]";
    default: return null;
  }
}


const GRAPH = `https://graph.facebook.com/${Deno.env.get("WA_GRAPH_VERSION") ?? "v21.0"}`;

/** Tipos que trazem arquivo: a Meta manda so um id, o binario e baixado depois. */
function midiaDe(msg: any): { id: string; mime?: string; filename?: string } | null {
  for (const t of ["image", "video", "audio", "document", "sticker"]) {
    if (msg?.[t]?.id) return { id: msg[t].id, mime: msg[t].mime_type, filename: msg[t].filename };
  }
  return null;
}

const EXT: Record<string, string> = {
  "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
  "video/mp4": "mp4", "video/3gpp": "3gp",
  "audio/ogg": "ogg", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/amr": "amr",
  "application/pdf": "pdf",
};
function extDe(mime?: string, filename?: string): string {
  if (filename?.includes(".")) return filename.split(".").pop()!.toLowerCase().slice(0, 8);
  const base = (mime ?? "").split(";")[0].trim();
  return EXT[base] ?? (base.split("/")[1] ?? "bin").slice(0, 8);
}

/**
 * Baixa a midia da Meta e guarda no bucket 'documentos', no MESMO padrao de
 * caminho que o cockpit ja usa (clinic/conversa/arquivo) — assim o front
 * renderiza sem precisar de nenhuma alteracao.
 * Roda FORA da resposta do webhook: a Meta corta em poucos segundos.
 */
async function baixarMidia(
  mediaId: string, wamid: string, clinic: string, conv: string,
  token: string, telefone: string, mime?: string, filename?: string,
) {
  try {
    const meta = await fetch(`${GRAPH}/${mediaId}`, { headers: { Authorization: `Bearer ${token}` } });
    const info = await meta.json();
    if (!meta.ok || !info?.url) { console.error("midia: sem url", mediaId, info?.error); return; }

    const bin = await fetch(info.url, { headers: { Authorization: `Bearer ${token}` } });
    if (!bin.ok) { console.error("midia: download falhou", mediaId, bin.status); return; }
    const bytes = new Uint8Array(await bin.arrayBuffer());

    const ext = extDe(info.mime_type ?? mime, filename);
    const path = `${clinic}/${conv}/${Date.now()}_${crypto.randomUUID().slice(0, 5)}.${ext}`;
    const { error } = await sb.storage.from("documentos")
      .upload(path, bytes, { contentType: info.mime_type ?? mime ?? "application/octet-stream", upsert: false });
    if (error) { console.error("midia: upload falhou", error.message); return; }

    await sb.rpc("nx_wa_media_set", { p_wamid: wamid, p_path: path });

    // Audio: transcreve e joga o texto na triagem, como se a pessoa tivesse
    // digitado. E o unico caminho para o bot entender quem manda audio.
    if ((info.mime_type ?? mime ?? "").startsWith("audio")) {
      const texto = await transcrever(bytes, info.mime_type ?? mime ?? "audio/ogg");
      if (texto) {
        await sb.rpc("nx_wa_set_transcript", { p_wamid: wamid, p_texto: texto });
        await responderBot(conv, texto, telefone, clinic);
      } else {
        // sem chave ou falha: nao deixa a pessoa sem resposta
        await enviarTexto(clinic, conv, telefone,
          "📎 Recebi o áudio! Ainda não consegui ouvir por aqui. "
          + "Pode escrever em texto, por favor?", "assistente");
      }
    }
  } catch (e) {
    console.error("midia:", e instanceof Error ? e.message : e);
  }
}


/**
 * Roda o roteiro de triagem (nx_wa_orchestrate) e, se ele tiver o que dizer,
 * MANDA de verdade pela Graph API. Sem esta parte o bot decide e ninguem ve:
 * era o que acontecia na producao, onde a resposta so era gravada no banco.
 * Roda fora da resposta do webhook — a Meta corta em poucos segundos.
 */
async function responderBot(conv: string, texto: string, telefone: string, clinic: string) {
  try {
    // O agente (wa-agent) decide o que responder. Ele ja aplica risco,
    // dados coletados e encaminhamento no banco antes de devolver o texto.
    const r = await fetch(`${URL_SB}/functions/v1/wa-agent`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
        "x-nx-internal": Deno.env.get("WA_INTERNAL_SECRET") ?? "",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ conversation_id: conv, texto }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { console.error("agente:", JSON.stringify(j)); return; }
    if (!j?.resposta) return;   // bot desligado, humano assumiu, ou nada a dizer

    await enviarTexto(clinic, conv, telefone, j.resposta, "assistente");
  } catch (e) {
    console.error("bot:", e instanceof Error ? e.message : e);
  }
}

/** Palavras que zeram a conversa. So no ambiente de trabalho. */
const CMD_ZERAR = ["zerar", "#zerar", "reset", "#reset", "recomecar", "recomeçar"];

/**
 * Comando de teste: apaga a conversa e responde confirmando, sem deixar rastro
 * na fila. Serve para testar a triagem do zero sem sair do WhatsApp.
 */
async function zerarConversa(phoneId: string, telefone: string): Promise<boolean> {
  try {
    const { data: r } = await sb.rpc("nx_dev_reset", { p_telefone: telefone });
    const { data: conn } = await sb.from("clinic_whatsapp")
      .select("access_token, phone_number_id").eq("phone_number_id", phoneId).single();
    if (!conn?.access_token) return true;

    const n = r?.conversas_apagadas ?? 0;
    const texto = n
      ? `🧹 Conversa zerada (${r.mensagens} mensagens apagadas).${"\n"}Manda qualquer coisa que a triagem começa do zero.`
      : `🧹 Já estava limpo. Manda qualquer coisa que a triagem começa.`;

    await fetch(`${GRAPH}/${conn.phone_number_id}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${conn.access_token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ messaging_product: "whatsapp", to: telefone, type: "text", text: { body: texto } }),
    });
  } catch (e) {
    console.error("zerar:", e instanceof Error ? e.message : e);
  }
  return true;
}


/** Manda um texto pelo numero da clinica e registra a mensagem enviada. */
async function enviarTexto(clinic: string, conv: string, telefone: string, texto: string, autor: string) {
  const { data: conn } = await sb.from("clinic_whatsapp")
    .select("access_token, phone_number_id").eq("clinic_id", clinic).single();
  if (!conn?.access_token) { console.error("envio: clinica sem token"); return; }

  const r = await fetch(`${GRAPH}/${conn.phone_number_id}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${conn.access_token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp", to: telefone, type: "text", text: { body: texto },
    }),
  });
  const out = await r.json().catch(() => ({}));
  if (!r.ok) { console.error("envio: Meta recusou", JSON.stringify(out?.error ?? out)); return; }

  await sb.rpc("nx_wa_record_out", {
    p_conv: conv, p_body: texto,
    p_wamid: out?.messages?.[0]?.id ?? null, p_type: "text", p_author: autor,
  });
}

/**
 * Arquivo recebido sem legenda. Sem resposta, a pessoa nao sabe se chegou:
 * reenvia, ou desiste. Confirma o recebimento e reconduz a conversa.
 */
async function avisarMidia(conv: string, clinic: string, telefone: string, tipo: string) {
  try {
    const { data: texto } = await sb.rpc("nx_wa_midia_ack", { p_conv: conv, p_tipo: tipo });
    if (texto) await enviarTexto(clinic, conv, telefone, texto, "assistente");
  } catch (e) {
    console.error("ack midia:", e instanceof Error ? e.message : e);
  }
}


/**
 * Transcreve o audio do paciente. Numa clinica pediatrica isto nao e luxo:
 * mae com crianca no colo manda audio, nao texto. Sem transcrever, a triagem
 * simplesmente para.
 * Usa Whisper da OpenAI; se nao houver chave configurada, devolve null e o
 * fluxo cai no aviso pedindo texto — degradado, mas honesto.
 */
async function transcrever(bytes: Uint8Array, mime: string): Promise<string | null> {
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) return null;
  try {
    const fd = new FormData();
    fd.append("file", new Blob([bytes], { type: mime || "audio/ogg" }), "audio.ogg");
    fd.append("model", Deno.env.get("WA_STT_MODEL") ?? "whisper-1");
    fd.append("language", "pt");
    // Contexto ajuda o modelo com termos que aparecem muito nesse dominio.
    fd.append("prompt", "Atendimento de clínica pediátrica: febre, tosse, vômito, "
      + "diarreia, mamada, vacina, consulta, remédio, alergia, garganta, ouvido.");

    const r = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}` },
      body: fd,
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { console.error("transcricao:", JSON.stringify(j?.error ?? j)); return null; }
    const texto = (j?.text ?? "").trim();
    return texto.length ? texto : null;
  } catch (e) {
    console.error("transcricao:", e instanceof Error ? e.message : e);
    return null;
  }
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // 0) Saude: diz se os segredos estao configurados, sem revelar valor algum.
  if (url.pathname.endsWith("/health")) {
    return Response.json({
      ok: true,
      app_secret_configurado: !!Deno.env.get("WA_APP_SECRET"),
      app_secret_mvf_configurado: !!Deno.env.get("WA_APP_SECRET_MVF"),
      verify_token_configurado: !!Deno.env.get("WA_VERIFY_TOKEN"),
    });
  }

  // 1) Verificacao do webhook (GET). O verify token e do APP, nao da clinica:
  //    com app unico a Meta chama esta URL uma vez so.
  if (req.method === "GET") {
    const modo = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const desafio = url.searchParams.get("hub.challenge") ?? "";
    const esperado = Deno.env.get("WA_VERIFY_TOKEN") ?? "";
    if (modo === "subscribe" && esperado && token === esperado) {
      return new Response(desafio, { status: 200, headers: { "content-type": "text/plain" } });
    }
    return new Response("forbidden", { status: 403 });
  }

  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const raw = await req.text();

  // 2) Assinatura. Sem isso qualquer um injeta mensagem na fila de uma clinica.
  const ok = await assinaturaValida(raw, req.headers.get("x-hub-signature-256"));
  if (!ok) return new Response("invalid signature", { status: 401 });

  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response("ok", { status: 200 }); }

  // 3) Rede de seguranca: guarda o payload cru ANTES de processar. Enquanto
  //    nx_wa_ingest/nx_wa_status nao existirem, nada se perde.
  try {
    await sb.from("webhook_events").insert({
      event_type: "whatsapp", origem: "meta_cloud", payload: body,
    });
  } catch (e) {
    console.error("webhook_events", e instanceof Error ? e.message : e);
  }

  // 4) Processa tudo, mas SEMPRE responde 200: erro nosso faz a Meta reentregar
  //    em backoff e, depois de muitas falhas, desinscrever o app.
  try {
    for (const entry of body?.entry ?? []) {
      for (const change of entry?.changes ?? []) {
        if (change?.field !== "messages") continue;
        const v = change.value ?? {};
        const phoneId = v.metadata?.phone_number_id;   // <- a chave do roteamento
        if (!phoneId) continue;

        const nome = v.contacts?.[0]?.profile?.name ?? null;

        for (const msg of v.messages ?? []) {
          // Comando de teste: nao entra na fila, nao passa pelo bot.
          const cmd = (corpoDe(msg) ?? "").trim().toLowerCase();
          if (CMD_ZERAR.includes(cmd)) {
            EdgeRuntime.waitUntil(zerarConversa(phoneId, msg.from));
            continue;
          }

          const mid = midiaDe(msg);
          const { data: ctx } = await sb.rpc("nx_wa_ingest", {
            p_phone_number_id: phoneId,
            p_from: msg.from,
            p_nome: nome,
            p_type: msg.type,
            p_body: corpoDe(msg),
            p_wamid: msg.id,                  // idempotencia: a Meta reentrega
            p_ts: Number(msg.timestamp ?? 0),
            p_payload: msg,
            p_media_id: mid?.id ?? null,
          });

          // Triagem automatica: o bot le a mensagem e responde, se for o caso.
          // Tambem fora da resposta do webhook, pelo mesmo motivo da midia.
          if (ctx?.conversation_id && ctx?.clinic_id) {
            const texto = corpoDe(msg);
            if (texto) {
              EdgeRuntime.waitUntil(
                responderBot(ctx.conversation_id, texto, msg.from, ctx.clinic_id),
              );
            } else if (mid && msg.type !== "audio") {
              // arquivo sem legenda: confirma o recebimento em vez de ficar mudo.
              // audio fica de fora: quem responde e a transcricao, mais adiante.
              EdgeRuntime.waitUntil(
                avisarMidia(ctx.conversation_id, ctx.clinic_id, msg.from, msg.type),
              );
            }
          }

          // Arquivo: baixa DEPOIS de responder 200. Se demorar aqui dentro, a
          // Meta considera falha e reentrega o evento inteiro.
          if (mid && ctx?.clinic_id && ctx?.conversation_id) {
            const { data: conn } = await sb.from("clinic_whatsapp")
              .select("access_token").eq("clinic_id", ctx.clinic_id).single();
            if (conn?.access_token) {
              EdgeRuntime.waitUntil(baixarMidia(
                mid.id, msg.id, ctx.clinic_id, ctx.conversation_id,
                conn.access_token, msg.from, mid.mime, mid.filename,
              ));
            }
          }
        }

        for (const st of v.statuses ?? []) {
          await sb.rpc("nx_wa_status", {
            p_phone_number_id: phoneId,
            p_wamid: st.id,
            p_status: st.status,              // sent | delivered | read | failed
            p_ts: Number(st.timestamp ?? 0),
            p_erro: st.errors?.[0] ?? null,   // 131047, 131026, 470...
          });
        }
      }
    }
  } catch (e) {
    console.error("wa-webhook", e instanceof Error ? e.message : e);
  }

  return new Response("ok", { status: 200 });
});
