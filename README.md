# NexoClin

Gestão do WhatsApp médico — landing + plataforma (cockpit de atendimento, relatórios e integrações).

## Estrutura
- `index.html` — landing page (captura de e-mail ligada ao Supabase).
- `nexoclin.html` — plataforma (login por perfil, cockpit, relatórios, integrações). Também acessível em `/plataforma` e `/app`.
- `vercel.json` — rotas e cabeçalhos (site estático, sem build).

## Backend (Supabase)
- Projeto: `kzbazzwfdagfhyxuadqp`
- URL: `https://kzbazzwfdagfhyxuadqp.supabase.co`
- Chave pública (client-safe): `sb_publishable_3BdfmucRk66Dc4bY2mA80w_CZEodm_L`
- Tabelas: `profiles`, `conversations`, `messages`, `collected_data`, `documents`, `webhook_events`, `waitlist` (todas com RLS).
- A landing grava e-mails em `public.waitlist` (política permite apenas INSERT anônimo).

> A chave `service_role` e tokens do WhatsApp NUNCA vão no front — ficam em variáveis de ambiente do servidor/edge function.

## Deploy (Vercel + GitHub, auto-update)
1. Crie um repositório no GitHub e envie estes arquivos (veja abaixo).
2. Em vercel.com → **Add New → Project → Import** o repositório.
3. Framework preset: **Other** (site estático, sem build). Deploy.
4. Pronto: cada `git push` na branch de produção republica sozinho.

### Enviar para o GitHub
```bash
git init
git add .
git commit -m "NexoClin: landing + plataforma"
git branch -M main
git remote add origin https://github.com/SEU_USUARIO/nexoclin.git
git push -u origin main
```
