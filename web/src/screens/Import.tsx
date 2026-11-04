import { useState, type ChangeEvent } from "react";
import { FunctionsHttpError } from "@supabase/supabase-js";
import { supabase, supabaseAnonKey, supabaseUrl } from "../supabase";
import { formatDate } from "../dates";
import { errorText } from "../errors";
import { TYPE_TITLES, type EntryType } from "../entries";
import { filenameFromDisposition } from "../exportPeriod";
import {
  defaultExcluded,
  fileErrorText,
  nbkRatePairs,
  rowAmount,
  rowErrorText,
  type FileError,
  type ImportRow,
  type Preview,
  type PreviewRow,
} from "../importPreview";

type Format = "csv" | "xlsx" | "json";

const TEMPLATES: { id: Format; label: string }[] = [
  { id: "csv", label: "CSV" },
  { id: "xlsx", label: "Excel" },
  { id: "json", label: "JSON" },
];

type State =
  | { kind: "idle" }
  | { kind: "busy"; step: string }
  | { kind: "file_error"; filename: string; errors: FileError[] }
  | { kind: "preview"; filename: string; preview: Preview; excluded: number[] }
  | { kind: "committing"; filename: string; preview: Preview; excluded: number[] }
  | { kind: "failed"; filename: string; preview: Preview }
  | { kind: "done"; filename: string; created: number; skipped: number }
  | { kind: "error"; message: string };

async function functionError(error: unknown): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    try {
      return ((await (error.context as Response).json()) as { error?: string }).error ?? "";
    } catch {
      return "";
    }
  }
  return "";
}

/**
 * Импорт (док 04, раздел 8; ADR-0004): шаблон и правила схемы, загрузка файла, предпросмотр по
 * строкам с ошибками и возможными дублями, подтверждение. Файл разбирает Edge Function
 * `import_parse`, проверяет и создаёт записи сервер (`import_preview`, `import_commit`); клиент
 * только показывает отчёт.
 */
export function Import() {
  const [state, setState] = useState<State>({ kind: "idle" });
  const [templateError, setTemplateError] = useState<string | null>(null);
  const [onlyProblems, setOnlyProblems] = useState(true);

  async function downloadTemplate(format: Format) {
    setTemplateError(null);
    try {
      const { data } = await supabase.auth.getSession();
      const res = await fetch(`${supabaseUrl}/functions/v1/import_parse?template=${format}`, {
        headers: { Authorization: `Bearer ${data.session?.access_token ?? ""}`, apikey: supabaseAnonKey },
      });
      if (!res.ok) return setTemplateError("Не получилось скачать шаблон. Попробуйте ещё раз.");
      const href = URL.createObjectURL(await res.blob());
      const link = document.createElement("a");
      link.href = href;
      link.download = filenameFromDisposition(res.headers.get("Content-Disposition"), `import_template.${format}`);
      document.body.append(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(href), 1000);
    } catch {
      setTemplateError("Нет связи с сервером. Проверьте интернет и попробуйте ещё раз.");
    }
  }

  async function choose(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    setOnlyProblems(true);
    setState({ kind: "busy", step: "Читаем файл…" });
    const form = new FormData();
    form.append("file", file);
    const parsed = await supabase.functions.invoke("import_parse", { body: form });
    if (parsed.error) {
      const code = await functionError(parsed.error);
      return setState(
        code === "file_too_large"
          ? { kind: "file_error", filename: file.name, errors: [{ code }] }
          : { kind: "error", message: code ? errorText({ message: code }) : "Сервер не ответил. Попробуйте ещё раз." },
      );
    }
    const body = parsed.data as { filename: string; format: Format | null; rows: ImportRow[]; errors: FileError[] };
    if (body.errors.length > 0) return setState({ kind: "file_error", filename: file.name, errors: body.errors });

    // Курс Нацбанка для валютных строк кладёт в кэш fetch_rates; нет курса — предпросмотр скажет.
    const pairs = nbkRatePairs(body.rows);
    if (pairs.length > 0) {
      setState({ kind: "busy", step: "Берём курсы Нацбанка…" });
      await Promise.all(pairs.map((p) => supabase.functions.invoke("fetch_rates", { body: p })));
    }

    setState({ kind: "busy", step: "Проверяем строки…" });
    const { data, error } = await supabase.rpc("import_preview", {
      p_rows: body.rows,
      p_filename: file.name,
      p_format: body.format,
    });
    if (error) return setState({ kind: "error", message: errorText(error) });
    const preview = data as Preview;
    setState({ kind: "preview", filename: file.name, preview, excluded: defaultExcluded(preview.rows) });
  }

  async function commit(filename: string, preview: Preview, excluded: number[]) {
    setState({ kind: "committing", filename, preview, excluded });
    const { data, error } = await supabase.rpc("import_commit", { p_batch_id: preview.batch_id, p_exclude_lines: excluded });
    if (error) return setState({ kind: "error", message: errorText(error) });
    const result = data as Preview & { ok: boolean; created: number; skipped: number };
    if (!result.ok) return setState({ kind: "failed", filename, preview: result });
    setState({ kind: "done", filename, created: result.created, skipped: result.skipped });
  }

  const busy = state.kind === "busy" || state.kind === "committing";

  return (
    <div className="import">
      <p className="muted import__lead">
        Файл той же схемы, что у экспорта: CSV, Excel или JSON. Можно загрузить архив экспорта целиком. Сначала покажем, что
        создастся, и только после подтверждения запишем.
      </p>

      <section className="import__template" aria-labelledby="import-template">
        <h2 id="import-template">Шаблон</h2>
        <div className="import__template-buttons">
          {TEMPLATES.map((t) => (
            <button key={t.id} className="button button--quiet" type="button" onClick={() => void downloadTemplate(t.id)}>
              Скачать шаблон {t.label}
            </button>
          ))}
        </div>
        {templateError && (
          <p className="error" role="alert">
            {templateError}
          </p>
        )}
        <SchemaRules />
      </section>

      <div className="import__upload">
        <label className="button button--primary import__file" aria-disabled={busy}>
          <input
            type="file"
            accept=".csv,.xlsx,.json,.zip,text/csv,application/json,application/zip,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            onChange={(e) => void choose(e)}
            disabled={busy}
          />
          {state.kind === "idle" || state.kind === "busy" || state.kind === "error" ? "Выбрать файл" : "Выбрать другой файл"}
        </label>
        <p aria-live="polite" className={state.kind === "error" ? "error" : "muted"} role={state.kind === "error" ? "alert" : undefined}>
          {state.kind === "busy" && state.step}
          {state.kind === "error" && state.message}
        </p>
      </div>

      {state.kind === "file_error" && (
        <div className="import__problem" role="alert">
          <p>Файл «{state.filename}» не загрузить:</p>
          <ul>
            {state.errors.map((e) => (
              <li key={e.code}>{fileErrorText(e)}</li>
            ))}
          </ul>
        </div>
      )}

      {state.kind === "done" && (
        <p className="import__done" role="status">
          {state.created > 0 ? `Загружено записей: ${state.created}.` : "Новых записей нет."}
          {state.skipped > 0 && ` Пропущено строк: ${state.skipped} (уже загружены или оставлены вами).`}
        </p>
      )}

      {(state.kind === "preview" || state.kind === "committing" || state.kind === "failed") && (
        <PreviewList
          filename={state.filename}
          preview={state.preview}
          failed={state.kind === "failed"}
          excluded={state.kind === "failed" ? [] : state.excluded}
          onlyProblems={onlyProblems}
          onOnlyProblems={setOnlyProblems}
          onToggle={(line) => {
            if (state.kind !== "preview") return;
            const excluded = state.excluded.includes(line)
              ? state.excluded.filter((l) => l !== line)
              : [...state.excluded, line];
            setState({ ...state, excluded });
          }}
          committing={state.kind === "committing"}
          onCommit={() => {
            if (state.kind === "preview") void commit(state.filename, state.preview, state.excluded);
          }}
        />
      )}
    </div>
  );
}

function PreviewList(props: {
  filename: string;
  preview: Preview;
  failed: boolean;
  excluded: number[];
  onlyProblems: boolean;
  onOnlyProblems: (v: boolean) => void;
  onToggle: (line: number) => void;
  committing: boolean;
  onCommit: () => void;
}) {
  const { preview, excluded } = props;
  const rows = preview.rows;
  const errors = rows.filter((r) => r.status === "error").length;
  const toCreate = rows.filter((r) => r.status === "create" && !excluded.includes(r.line)).length;
  const skipped = rows.filter((r) => r.status === "skip").length;
  const duplicates = rows.filter((r) => r.duplicates.length > 0 && r.status !== "error").length;
  const problem = (r: PreviewRow) => r.status === "error" || r.duplicates.length > 0;
  const problems = rows.filter(problem).length;
  const shown = props.onlyProblems && problems > 0 ? rows.filter(problem) : rows;

  return (
    <section className="import__preview" aria-labelledby="import-preview">
      <h2 id="import-preview">{props.failed ? "Файл не загружен" : "Что создастся"}</h2>
      <p className="import__summary">
        {props.filename}: строк {rows.length}. Создастся {toCreate}
        {skipped > 0 && `, уже загружены ${skipped}`}
        {duplicates > 0 && `, возможных дублей ${duplicates}`}
        {errors > 0 && `, с ошибками ${errors}`}.
      </p>
      {errors > 0 && (
        <p className="import__problem" role="alert">
          {props.failed ? "Ни одна запись не создана. " : ""}
          При ошибке хотя бы в одной строке файл не загружается целиком. Исправьте строки ниже и загрузите файл заново.
        </p>
      )}
      {duplicates > 0 && errors === 0 && !props.failed && (
        <p className="muted">
          Возможный дубль похож на запись в пределах трёх дней. Такие строки не создадутся, пока вы не отметите «Создать всё
          равно».
        </p>
      )}

      {problems > 0 && problems < rows.length && (
        <fieldset className="choice import__filter">
          <legend>Какие строки показать</legend>
          <div className="choice__options">
            <label className="choice__option">
              <input type="radio" name="import-filter" checked={props.onlyProblems} onChange={() => props.onOnlyProblems(true)} />
              <span>Требуют внимания: {problems}</span>
            </label>
            <label className="choice__option">
              <input type="radio" name="import-filter" checked={!props.onlyProblems} onChange={() => props.onOnlyProblems(false)} />
              <span>Все строки: {rows.length}</span>
            </label>
          </div>
        </fieldset>
      )}

      <ul className="import__rows">
        {shown.map((r) => (
          <PreviewItem
            key={r.line}
            row={r}
            excluded={excluded.includes(r.line)}
            disabled={props.failed || props.committing}
            onToggle={() => props.onToggle(r.line)}
          />
        ))}
      </ul>

      {!props.failed && (
        <button
          className="button button--primary"
          type="button"
          disabled={errors > 0 || toCreate === 0 || props.committing}
          aria-busy={props.committing}
          onClick={props.onCommit}
        >
          {props.committing ? "Загружаем…" : toCreate === 0 ? "Создавать нечего" : `Загрузить записей: ${toCreate}`}
        </button>
      )}
    </section>
  );
}

const STATUS_TEXT: Record<PreviewRow["status"], string> = {
  create: "создастся",
  skip: "уже загружена, пропустим",
  excluded: "не создастся",
  error: "ошибка",
};

function PreviewItem({ row, excluded, disabled, onToggle }: { row: PreviewRow; excluded: boolean; disabled: boolean; onToggle: () => void }) {
  const type = row.type && row.type in TYPE_TITLES ? TYPE_TITLES[row.type as EntryType] : (row.type ?? "Без типа");
  const what = row.title ?? row.category ?? type;
  const where = row.to_account
    ? `с «${row.account ?? "счёта"}» на «${row.to_account}»`
    : row.account
      ? `«${row.account}»`
      : null;
  const status = row.status === "create" && excluded ? "не создастся" : STATUS_TEXT[row.status];
  return (
    <li className={`import-row import-row--${row.status}${row.duplicates.length > 0 ? " import-row--duplicate" : ""}`}>
      <span className="import-row__line muted">стр. {row.line}</span>
      <span className="import-row__head">
        <span className="import-row__title">{what}</span>
        <span className="import-row__amount amount">{rowAmount(row)}</span>
      </span>
      <span className="import-row__meta muted">
        {[row.occurred_on && formatDate(row.occurred_on), what === type ? null : type, where].filter(Boolean).join(", ")}
        {", "}
        <span className={row.status === "error" ? "error" : undefined}>{status}</span>
      </span>
      {row.errors.length > 0 && (
        <ul className="import-row__errors">
          {row.errors.map((e, i) => (
            <li key={i}>{rowErrorText(e)}</li>
          ))}
        </ul>
      )}
      {row.duplicates.length > 0 && row.status !== "error" && (
        <div className="import-row__duplicate">
          <span>
            Похоже на{" "}
            {row.duplicates
              .map((d) =>
                d.line ? `строку ${d.line} этого файла` : `запись ${formatDate(d.occurred_on)}${d.title ? ` «${d.title}»` : ""}`,
              )
              .join(", ")}
          </span>
          {row.status === "create" && (
            <label className="import-row__keep">
              <input type="checkbox" checked={!excluded} disabled={disabled} onChange={onToggle} />
              Создать всё равно
            </label>
          )}
        </div>
      )}
    </li>
  );
}

/** Правила схемы для людей и Claude (док 04, раздел 8): то же, что проверяет импорт. */
function SchemaRules() {
  return (
    <details className="import__rules">
      <summary>Правила схемы</summary>
      <ul>
        <li>Одна строка = одна запись. Обязательны колонки occurred_on, type и amount, остальные можно опустить.</li>
        <li>Дата в виде 2026-11-04. Сумма с точкой, без пробелов, не больше двух знаков: 1500.00. Минус пишется -1500.00 или (1500.00).</li>
        <li>
          Знак суммы показывает движение денег по счёту: трата, перевод, изъятие аванса и «я отдал компании» с минусом;
          поступление, пополнение от компании, возврат покупки, «компания отдала мне» и взаимозачёт с плюсом. У корректировки
          знак задаёт её направление. Комиссия всегда с минусом.
        </li>
        <li>Счета и категории сопоставляются по точному названию, как в приложении. Неизвестное название = ошибка строки.</li>
        <li>У личной траты укажите, чьими деньгами: source = own или company.</li>
        <li>
          external_id защищает от повторов: строка с уже загруженным значением пропускается. Возврат покупки указывает свою
          трату её external_id в parent_external_id.
        </li>
        <li>Ошибка хотя бы в одной строке отменяет весь файл. Возможный дубль не ошибка: вы решаете, создавать ли его.</li>
      </ul>
      <table className="import__columns">
                <thead>
          <tr>
            <th scope="col">Колонка</th>
            <th scope="col">Значение</th>
          </tr>
        </thead>
        <tbody>
          {COLUMN_RULES.map(([name, rule]) => (
            <tr key={name}>
              <th scope="row">{name}</th>
              <td>{rule}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </details>
  );
}

const COLUMN_RULES: [string, string][] = [
  ["occurred_on", "дата записи"],
  ["type", "expense, income, transfer, company_topup, company_advance_return, settlement, netting, adjustment, refund"],
  ["account", "название счёта; у перевода «откуда»"],
  ["amount", "сумма со знаком по правилу выше"],
  ["currency", "KZT, USD…; пусто = валюта счёта"],
  ["category", "название категории (трата, поступление)"],
  ["source", "own или company (личная трата)"],
  ["purpose", "personal или work (трата)"],
  ["transfer_purpose", "move_own, move_company, repay_debt, take_advance"],
  ["to_account", "название счёта «куда»"],
  ["fee", "комиссия, с минусом; пусто = без комиссии"],
  ["fee_payer", "own или company"],
  ["comment, title", "текст"],
  ["external_id", "ваш идентификатор строки"],
  ["settlement_direction", "i_paid_company или company_paid_me"],
  ["adjustment_target", "balance, company_owes_me, i_owe_company"],
  ["adjustment_mode", "plug_hidden или plug_analytics"],
  ["adjustment_affects_advance", "true, если корректировка остатка касается денег компании"],
  ["parent_external_id", "external_id траты у возврата покупки"],
  ["rate, rate_source", "курс тенге за 1 единицу и nbk, manual или derived"],
  ["amount_kzt", "сумма в тенге, со знаком суммы"],
  ["in_analytics", "true или false"],
];
