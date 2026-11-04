// Edge Function claude_ingest: настоящие зависимости для handler.ts. JWT пользователя здесь нет
// (verify_jwt = false в config.toml): доступ решает служебный токен, а RPC claude_ingest зовётся
// ключом service_role, которому одному она разрешена. Ссылки на скрины заметок подписываются на
// 10 минут тем же ключом (бакет `files` приватный). Ссылка отдаётся путём от адреса API
// (`/storage/v1/object/sign/...`): изнутри стека SUPABASE_URL внутренний (`http://kong:8000`), а
// снаружи Claude Code знает адрес, на который сам зовёт функцию.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { type Deps, handleClaudeIngest, type IngestResult } from "./handler.ts";

const SIGNED_URL_SECONDS = 600;

const service = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const deps: Deps = {
  async ingest(tokenHash, request) {
    const { data, error } = await service.rpc("claude_ingest", { p_token_hash: tokenHash, p_request: request });
    if (error) throw error;
    return data as IngestResult;
  },
  async signedUrl(path) {
    const { data, error } = await service.storage.from("files").createSignedUrl(path, SIGNED_URL_SECONDS);
    if (error) return null;
    const signed = new URL(data.signedUrl);
    return signed.pathname + signed.search;
  },
};

Deno.serve((req) => handleClaudeIngest(req, deps));
