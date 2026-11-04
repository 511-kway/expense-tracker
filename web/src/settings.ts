import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";

export type SettingsState =
  | { kind: "loading" }
  | { kind: "first-run" }
  | { kind: "ready"; accountingStartDate: string }
  | { kind: "error" };

/** Настройки пользователя. Строки нет, пока не пройден первый запуск (setup_start, ADR-0008). */
export function useSettings(): [SettingsState, () => void] {
  const [state, setState] = useState<SettingsState>({ kind: "loading" });

  const load = useCallback(async () => {
    const { data, error } = await supabase.from("user_settings").select("accounting_start_date").maybeSingle();
    if (error) setState({ kind: "error" });
    else if (!data) setState({ kind: "first-run" });
    else setState({ kind: "ready", accountingStartDate: data.accounting_start_date as string });
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  return [state, () => void load()];
}
