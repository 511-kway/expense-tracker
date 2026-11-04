import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

if (!url || !anonKey) {
  throw new Error("VITE_SUPABASE_URL и VITE_SUPABASE_ANON_KEY не заданы, см. web/.env.example");
}

export const supabaseUrl = url;
// PKCE: после входа в адресе приходит ?code=, а не токены в #hash.
export const supabase = createClient(url, anonKey, { auth: { flowType: "pkce" } });

/**
 * Вход по ссылке из письма: только `vite dev` с VITE_DEV_EMAIL_LOGIN=true (docs/dev.md).
 * В сборке (`vite build`) import.meta.env.DEV = false, и форма вырезается при любом флаге.
 */
export const devEmailLogin = import.meta.env.DEV && import.meta.env.VITE_DEV_EMAIL_LOGIN === "true";
