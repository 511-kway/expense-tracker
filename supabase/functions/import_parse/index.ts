// Edge Function import_parse: настоящие зависимости для handler.ts. Доступ проверяется клиентом с
// JWT пользователя (is_allowed, ADR-0007); сама функция в базу не ходит и ничего не пишет.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { type Deps, handleImportParse } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const deps: Deps = {
  async isAllowed(authorization) {
    if (!authorization) return false;
    const client = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authorization } },
    });
    const { data, error } = await client.rpc("is_allowed");
    return !error && data === true;
  },
};

Deno.serve((req) => handleImportParse(req, deps));
