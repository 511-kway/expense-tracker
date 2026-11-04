import { useState, type FormEvent } from "react";
import { supabase, supabaseAnonKey, supabaseUrl } from "../supabase";
import { formatDate, todayInAlmaty } from "../dates";
import { filenameFromDisposition, presetPeriod, type Period, type PeriodPreset } from "../exportPeriod";

type Format = "csv" | "xlsx" | "json";

const FORMATS: { id: Format; label: string }[] = [
  { id: "csv", label: "CSV" },
  { id: "xlsx", label: "Excel" },
  { id: "json", label: "JSON" },
];

const PRESETS: { id: PeriodPreset | "custom"; label: string }[] = [
  { id: "month", label: "Этот месяц" },
  { id: "last_month", label: "Прошлый месяц" },
  { id: "year", label: "Этот год" },
  { id: "all", label: "Всё время" },
  { id: "custom", label: "Свой период" },
];

const ERRORS: Record<string, string> = {
  not_allowed: "Добавили вас в лист ожидания",
  period_invalid: "Начало периода позже конца: поменяйте даты местами",
  field_invalid: "Проверьте даты периода",
};

function describe(period: Period, accountingStartDate: string): string {
  const from = formatDate(period.from ?? accountingStartDate);
  return period.to ? `с ${from} по ${formatDate(period.to)}` : `с ${from} по сегодня`;
}

/**
 * Экспорт (док 04, раздел 9): период и формат, один архив с двумя файлами. Файлы строит Edge
 * Function `export` (supabase/functions/export), клиент только скачивает ответ.
 */
export function Export({ accountingStartDate }: { accountingStartDate: string }) {
  const today = todayInAlmaty();
  const [preset, setPreset] = useState<PeriodPreset | "custom">("month");
  const [custom, setCustom] = useState<{ from: string; to: string }>({ from: accountingStartDate, to: today });
  const [format, setFormat] = useState<Format>("csv");
  const [state, setState] = useState<{ kind: "idle" | "busy" } | { kind: "done"; file: string } | { kind: "error"; message: string }>({
    kind: "idle",
  });

  const period: Period = preset === "custom" ? { from: custom.from || null, to: custom.to || null } : presetPeriod(preset, today);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (period.from && period.to && period.from > period.to) {
      return setState({ kind: "error", message: ERRORS.period_invalid! });
    }
    setState({ kind: "busy" });
    try {
      const { data } = await supabase.auth.getSession();
      const res = await fetch(`${supabaseUrl}/functions/v1/export`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${data.session?.access_token ?? ""}`,
          apikey: supabaseAnonKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ...period, format }),
      });
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        return setState({
          kind: "error",
          message: ERRORS[body?.error ?? ""] ?? "Не получилось собрать файлы: сервер не ответил. Попробуйте ещё раз.",
        });
      }
      const file = filenameFromDisposition(res.headers.get("Content-Disposition"), `export_${format}.zip`);
      const href = URL.createObjectURL(await res.blob());
      const link = document.createElement("a");
      link.href = href;
      link.download = file;
      document.body.append(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(href), 1000);
      setState({ kind: "done", file });
    } catch {
      setState({ kind: "error", message: "Нет связи с сервером. Проверьте интернет и попробуйте ещё раз." });
    }
  }

  return (
    <form className="export" onSubmit={submit} noValidate>
      <p className="muted export__lead">
        Архив с двумя файлами для анализа в Claude. Схема та же, что у импорта: файл можно загрузить обратно без
        правок.
      </p>

      <fieldset className="choice">
        <legend>Период</legend>
        <div className="choice__options">
          {PRESETS.map((p) => (
            <label key={p.id} className="choice__option">
              <input type="radio" name="export-period" checked={preset === p.id} onChange={() => setPreset(p.id)} />
              <span>{p.label}</span>
            </label>
          ))}
        </div>
      </fieldset>

      {preset === "custom" && (
        <div className="export__dates">
          <div className="field">
            <label htmlFor="export-from">С</label>
            <input
              id="export-from"
              type="date"
              value={custom.from}
              max={custom.to || undefined}
              onChange={(e) => setCustom({ ...custom, from: e.target.value })}
            />
          </div>
          <div className="field">
            <label htmlFor="export-to">По</label>
            <input
              id="export-to"
              type="date"
              value={custom.to}
              min={custom.from || undefined}
              onChange={(e) => setCustom({ ...custom, to: e.target.value })}
            />
          </div>
        </div>
      )}

      <fieldset className="choice">
        <legend>Формат</legend>
        <div className="choice__options choice__options--three">
          {FORMATS.map((f) => (
            <label key={f.id} className="choice__option">
              <input type="radio" name="export-format" checked={format === f.id} onChange={() => setFormat(f.id)} />
              <span>{f.label}</span>
            </label>
          ))}
        </div>
      </fieldset>

      <dl className="export__files">
        <div>
          <dt>expenses.{format}</dt>
          <dd>Записи {describe(period, accountingStartDate)}: тип, счёт, сумма, категория, назначение.</dd>
        </div>
        <div>
          <dt>company_settlement.{format}</dt>
          <dd>
            Движения с компанией за тот же период: насколько изменилась каждая сторона долга и сколько стало после записи.
          </dd>
        </div>
      </dl>
      <p className="field__hint">
        Даты в виде 2026-11-04, суммы с точкой и двумя знаками: трата -1500.00
        {format === "xlsx" ? ", в Excel минус показан красным в скобках, а ячейка остаётся числом." : "."}
      </p>

      <button className="button button--primary" type="submit" disabled={state.kind === "busy"} aria-busy={state.kind === "busy"}>
        {state.kind === "busy" ? "Собираем архив…" : "Скачать архив"}
      </button>
      <p aria-live="polite" className={state.kind === "error" ? "error" : "muted"} role={state.kind === "error" ? "alert" : undefined}>
        {state.kind === "done" && `Архив скачан: ${state.file}`}
        {state.kind === "error" && state.message}
      </p>
    </form>
  );
}
