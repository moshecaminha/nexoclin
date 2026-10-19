// supabase/functions/wa-signup/index.ts
// Conecta o WhatsApp oficial da clinica pela Zernio. A Zernio roda o
// Embedded Signup da Meta, troca o token, assina a WABA e sincroniza o
// historico da coexistencia; aqui so guardamos qual conta e de qual clinica.
//
// Acoes (POST):
//   iniciar     { clinic_id, modo: "coexistencia" | "api", voltar }  -> { url }
//               Gera o link do cadastro. `voltar` e a pagina que recebe o
//               retorno; vai com um estado de uso unico (?nx_zernio=).
//   concluir    { clinic_id, estado, account_id }  -> grava a conexao
//   contas_livres { clinic_id }  (admin da plataforma) contas da Zernio sem clinica
//   vincular    { clinic_id, account_id }  (admin da plataforma) liga uma delas
//   configurar  (x-nx-internal) cadastra/atualiza o webhook da Zernio.
//
// Travas: so gestor/admin conecta; a conta tem de estar no profile da
// NexoClin na Zernio; e nao pode estar ligada a outra clinica.
import { createClient } from "npm:@supabase/supabase-js@2";
import { zernio } from "../_shared/canal.ts";

const URL_SB  = Deno.env.get("SUPABASE_URL")!;
const SRV     = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON    = Deno.env.get("SUPABASE_ANON_KEY")!;
const PROFILE = Deno.env.get("ZERNIO_PROFILE_ID") ?? "";
const INTERNO = Deno.env.get("WA_INTERNAL_SECRET") ?? "";
const WEBHOOK = `${URL_SB}/functions/v1/wa-webhook`;

const EVENTOS = [
  "message.received", "message.sent", "message.delivered", "message.read", "message.failed",
  "account.disconnected",
];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

/** Cadastra (ou corrige) o webhook da Zernio apontando para a wa-webhook. */
async function configurarWebhook() {
  const segredo = Deno.env.get("ZERNIO_WEBHOOK_SECRET") ?? "";
  if (!segredo) return json({ erro: "ZERNIO_WEBHOOK_SECRET não configurado" }, 500);
  if (!Deno.env.get("ZERNIO_API_KEY")) return json({ erro: "ZERNIO_API_KEY não configurada" }, 500);
  const lista = await zernio("/webhooks/settings");
  if (!lista.ok) return json({ erro: "falha ao ler webhooks da Zernio", zernio: lista.body }, 502);
  const atual = ((lista.body?.webhooks ?? []) as any[]).find((w) => w?.url === WEBHOOK);
  const corpo = {
    name: "NexoClin", url: WEBHOOK, secret: segredo, events: EVENTOS, isActive: true,
    ...(PROFILE ? { profileIds: [PROFILE] } : {}),
  };
  const r = atual
    ? await zernio("/webhooks/settings", { ...corpo, _id: atual._id }, "PUT")
    : await zernio("/webhooks/settings", corpo);

  // Os lembretes saem do banco (pg_net) e leem a API key do vault.
  const admin = createClient(URL_SB, SRV);
  const { error: errKey } = await admin.rpc("nx_zernio_set_key", { p_key: Deno.env.get("ZERNIO_API_KEY") ?? "" });

  return json({
    ok: r.ok && !errKey, acao: atual ? "atualizado" : "criado", zernio: r.body,
    vault: errKey ? errKey.message : "ok",
  }, r.ok ? 200 : 502);
}

/** Contas de WhatsApp no profile da NexoClin na Zernio. */
async function contasDoProfile(): Promise<any[]> {
  const q = new URLSearchParams({ profileId: PROFILE, platform: "whatsapp", limit: "100" });
  const lista = await zernio(`/accounts?${q}`);
  return (lista.body?.accounts ?? []) as any[];
}

/**
 * Liga a conta da Zernio a clinica. `coex` null = le da propria Zernio
 * (metadata.isCoexistence), para contas vinculadas fora do cadastro.
 */
// deno-lint-ignore no-explicit-any
async function gravarConta(admin: any, clinic_id: string, conta: string, coex: boolean | null) {
  const acc = (await contasDoProfile()).find((a) => String(a?._id) === conta);
  if (!acc) return json({ erro: "conta não encontrada na Zernio" }, 404);

  const phoneId = `zernio:${conta}`;
  const { data: dono } = await admin.from("clinic_whatsapp")
    .select("clinic_id").eq("phone_number_id", phoneId).neq("clinic_id", clinic_id).limit(1);
  if (dono?.length) return json({ erro: "este número já está conectado em outra clínica da NexoClin." }, 409);

  const coexistencia = coex ?? (acc?.metadata?.isCoexistence === true);
  const agora = new Date().toISOString();
  const { error: errUp } = await admin.from("clinic_whatsapp").upsert({
    clinic_id, provider: "zernio",
    phone_number_id: phoneId, access_token: conta,
    waba_id: acc?.metadata?.wabaId ?? null, app_secret: null, api_url: null,
    display_number: acc?.username ?? acc?.displayName ?? null,
    status: acc?.isActive === false ? "pendente" : "conectado",
    coexistencia, is_on_biz_app: coexistencia,
    sync_contatos_id: null, sync_historico_id: null, sync_em: null,
    conexao_erro: acc?.isActive === false ? "conta inativa na Zernio" : null,
    verificado_em: agora, connected_at: agora, updated_at: agora,
  }, { onConflict: "clinic_id" });
  if (errUp) return json({ erro: "falha ao gravar", detalhe: errUp.message }, 500);

  return json({ ok: true, status: "conectado", numero: acc?.username, coexistencia });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST")    return json({ erro: "method not allowed" }, 405);

  let b: any;
  try { b = await req.json(); } catch { return json({ erro: "json inválido" }, 400); }

  if (b?.acao === "configurar") {
    if (!INTERNO || req.headers.get("x-nx-internal") !== INTERNO) return json({ erro: "forbidden" }, 403);
    return await configurarWebhook();
  }

  const jwt = req.headers.get("Authorization") ?? "";
  if (!jwt.startsWith("Bearer ")) return json({ erro: "sem autenticação" }, 401);
  if (!Deno.env.get("ZERNIO_API_KEY") || !PROFILE) {
    return json({ erro: "integração com a Zernio não configurada (ZERNIO_API_KEY / ZERNIO_PROFILE_ID)" }, 500);
  }

  const { clinic_id } = b ?? {};
  if (!clinic_id) return json({ erro: "clinic_id é obrigatório" }, 400);

  // So gestor/admin conecta. Checado com o JWT de quem clicou.
  const comoUsuario = createClient(URL_SB, ANON, { global: { headers: { Authorization: jwt } } });
  const { data: pode, error: errPerm } = await comoUsuario.rpc("nx_can_admin", { p_clinic: clinic_id });
  if (errPerm || pode !== true) return json({ erro: "sem permissão", detalhe: errPerm?.message }, 403);

  const admin = createClient(URL_SB, SRV);

  // 1) Link do cadastro. A pagina da Zernio abre o popup da Meta e devolve a
  //    pessoa para `voltar` com accountId (ou error) na URL.
  if (b?.acao === "iniciar") {
    const modo = b?.modo === "api" ? "api" : "coexistencia";
    let voltar: URL;
    try { voltar = new URL(String(b?.voltar ?? "")); } catch { return json({ erro: "voltar inválido" }, 400); }
    if (voltar.protocol !== "https:") return json({ erro: "voltar precisa ser https" }, 400);

    const { data: est, error: errEst } = await admin.from("wa_zernio_estado")
      .insert({ clinic_id, modo }).select("estado").single();
    if (errEst) return json({ erro: "falha ao iniciar", detalhe: errEst.message }, 500);
    voltar.searchParams.set("nx_zernio", est.estado);

    const q = new URLSearchParams({
      profileId: PROFILE, redirect_url: voltar.toString(),
      onboarding: modo === "api" ? "api" : "business_app",
      signup: "hosted", language: "pt-BR", brandName: "NexoClin",
    });
    const r = await zernio(`/connect/whatsapp?${q}`);
    if (!r.ok || !r.body?.authUrl) return json({ erro: "a Zernio recusou o início do cadastro", zernio: r.body }, 502);
    return json({ ok: true, url: r.body.authUrl });
  }

  // 2) Volta do cadastro: confere o estado e a conta, e grava.
  if (b?.acao === "concluir") {
    const conta = String(b?.account_id ?? "");
    if (!b?.estado || !conta) return json({ erro: "estado e account_id são obrigatórios" }, 400);

    // Estado de uso unico, da mesma clinica, criado ha menos de 1h.
    const { data: est } = await admin.from("wa_zernio_estado")
      .delete().eq("estado", b.estado).eq("clinic_id", clinic_id)
      .gt("criado_em", new Date(Date.now() - 3600_000).toISOString())
      .select("modo").maybeSingle();
    if (!est) return json({ erro: "cadastro expirado ou de outra clínica. Comece de novo." }, 409);

    return await gravarConta(admin, clinic_id, conta, est.modo === "coexistencia");
  }

  // 3) Contas conectadas direto no painel da Zernio ficam sem clinica: o
  //    webhook chega e e descartado. So o admin da plataforma ve e vincula,
  //    para um gestor nao pegar o numero de outra clinica.
  if (b?.acao === "contas_livres" || b?.acao === "vincular") {
    const { data: padmin } = await comoUsuario.rpc("is_platform_admin");
    if (padmin !== true) return json({ erro: "só o admin da plataforma" }, 403);

    if (b.acao === "vincular") {
      const conta = String(b?.account_id ?? "");
      if (!conta) return json({ erro: "account_id é obrigatório" }, 400);
      return await gravarConta(admin, clinic_id, conta, null);
    }

    const contas = await contasDoProfile();
    const { data: usadas } = await admin.from("clinic_whatsapp")
      .select("phone_number_id").like("phone_number_id", "zernio:%");
    const ligadas = new Set((usadas ?? []).map((u: any) => String(u.phone_number_id).slice(7)));
    return json({
      ok: true,
      contas: contas.filter((a) => !ligadas.has(String(a?._id))).map((a) => ({
        account_id: a._id, numero: a.username, nome: a.displayName,
        coexistencia: a?.metadata?.isCoexistence === true, ativa: a?.isActive !== false,
      })),
    });
  }

  return json({ erro: "ação inválida" }, 400);
});
