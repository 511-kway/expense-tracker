import { useEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";

export type AuthState =
  | { kind: "loading" }
  | { kind: "signed-out"; error?: string }
  | { kind: "waitlisted" }
  | { kind: "signed-in"; email: string; name: string | null }
  | { kind: "error"; message: string };

/**
 * Сессия плюс отметка «разрешён» (ADR-0007). После входа зовём register_login():
 * разрешён — внутрь, нет — экран листа ожидания и выход. Сервер всё равно ничего
 * не отдаёт неразрешённому (RLS), экран только объясняет, что произошло.
 */
export function useAuth(): [AuthState, () => void] {
  const [state, setState] = useState<AuthState>(() => {
    const error = oauthErrorFromUrl();
    return error ? { kind: "signed-out", error } : { kind: "loading" };
  });
  const checkedUser = useRef<string | null>(null);

  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === "SIGNED_OUT" || (event === "INITIAL_SESSION" && !session)) {
        checkedUser.current = null;
        setState((s) => (s.kind === "waitlisted" || s.kind === "signed-out" ? s : { kind: "signed-out" }));
        return;
      }
      if (session && checkedUser.current !== session.user.id) {
        checkedUser.current = session.user.id;
        // Нельзя ждать другие вызовы supabase внутри этого колбэка: отложим.
        setTimeout(() => void checkAccess(session), 0);
      }
    });
    return () => data.subscription.unsubscribe();
  }, []);

  async function checkAccess(session: Session) {
    const { data, error } = await supabase.rpc("register_login");
    if (error) {
      checkedUser.current = null;
      setState({ kind: "error", message: "Не получилось проверить доступ: сервер не ответил. Обновите страницу." });
      return;
    }
    if ((data as { allowed?: boolean } | null)?.allowed === true) {
      const meta = session.user.user_metadata as { full_name?: string; name?: string };
      setState({ kind: "signed-in", email: session.user.email ?? "", name: meta.full_name ?? meta.name ?? null });
    } else {
      setState({ kind: "waitlisted" });
      await supabase.auth.signOut();
    }
  }

  function signOut() {
    setState({ kind: "signed-out" });
    void supabase.auth.signOut();
  }

  return [state, signOut];
}

function oauthErrorFromUrl(): string | undefined {
  const params = new URLSearchParams(window.location.search || window.location.hash.slice(1));
  if (!params.get("error")) return undefined;
  window.history.replaceState(null, "", window.location.pathname);
  return "Вход не завершился. Попробуйте ещё раз.";
}
