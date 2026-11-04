import { useEffect, useState, type ReactNode } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatDate } from "../dates";
import { ENTRY_COLUMNS, entryTitle, formatSigned, type EntryRow } from "../entries";

/** Трата и поступление правятся в форме; остальные типы появятся со своими тикетами. */
const EDITABLE = new Set(["expense", "income"]);

/**
 * Лента записей по датам, новые сверху. У каждой строки сумма и что запись сделала с авансом
 * и долгом: числа из журнала сервера (v_entries), клиент их только показывает.
 */
export function Entries({ onEdit, onCreate }: { onEdit: (entry: EntryRow) => void; onCreate: () => void }) {
  const [rows, setRows] = useState<EntryRow[] | null | "error">(null);

  useEffect(() => {
    void (async () => {
      const { data, error } = await supabase
        .from("v_entries")
        .select(ENTRY_COLUMNS)
        .order("occurred_on", { ascending: false })
        .order("created_at", { ascending: false })
        .order("seq", { ascending: false })
        .limit(500);
      setRows(error || !data ? "error" : (data as unknown as EntryRow[]));
    })();
  }, []);

  if (rows === null) return <p className="muted" aria-busy="true">Загружаем записи…</p>;
  if (rows === "error")
    return (
      <p className="error" role="alert">
        Не получилось загрузить записи. Обновите страницу.
      </p>
    );
  if (rows.length === 0)
    return (
      <div className="empty">
        <p>Записей пока нет. Запишите первую трату.</p>
        <button className="button button--primary" type="button" onClick={onCreate}>
          Записать трату
        </button>
      </div>
    );

  const days: { date: string; rows: EntryRow[] }[] = [];
  for (const r of rows) {
    const last = days[days.length - 1];
    if (last && last.date === r.occurred_on) last.rows.push(r);
    else days.push({ date: r.occurred_on, rows: [r] });
  }

  return (
    <div className="feed">
      {days.map((d) => (
        <section key={d.date} className="feed__day" aria-label={formatDate(d.date)}>
          <h2 className="feed__date">{formatDate(d.date)}</h2>
          <ul className="feed__list">
            {d.rows.map((r) => (
              <li key={r.entry_id}>
                <EntryItem entry={r} onEdit={EDITABLE.has(r.type) ? () => onEdit(r) : undefined} />
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}

function EntryItem({ entry: e, onEdit }: { entry: EntryRow; onEdit?: () => void }) {
  const shown =
    e.balance_delta_minor !== 0
      ? e.balance_delta_minor
      : e.company_owes_me_delta_minor !== 0
        ? e.company_owes_me_delta_minor
        : e.i_owe_company_delta_minor;
  const content: ReactNode = (
    <>
      <span className="entry__head">
        <span className="entry__title">{entryTitle(e)}</span>
        <span className="entry__amount amount">{formatSigned(shown, e.currency)}</span>
      </span>
      <span className="entry__meta muted">{meta(e)}</span>
      <Effects entry={e} />
    </>
  );
  return onEdit ? (
    <button className="entry" type="button" onClick={onEdit} aria-label={`${entryTitle(e)}: изменить запись`}>
      {content}
    </button>
  ) : (
    <div className="entry entry--static">{content}</div>
  );
}

function meta(e: EntryRow): string {
  const parts: string[] = [];
  if (e.account_name) parts.push(e.account_name);
  if (e.type === "expense") {
    if (e.purpose === "work") parts.push("работа");
    else parts.push(e.source === "company" ? "личное, деньгами компании" : "личное");
  }
  if (e.type === "income" && e.category_name) parts.push("поступление");
  if (e.comment) parts.push(e.comment);
  return parts.join(", ");
}

/** Что запись сделала с авансом и сторонами долга: цвет «свои» и «компания» плюс подпись. */
function Effects({ entry: e }: { entry: EntryRow }) {
  const items: { side: "own" | "company"; label: string; value: string }[] = [];
  if (e.advance_delta_minor < 0)
    items.push({ side: "company", label: "Из аванса", value: formatMoney(-e.advance_delta_minor, "KZT") });
  if (e.advance_delta_minor > 0)
    items.push({ side: "company", label: "В аванс", value: formatMoney(e.advance_delta_minor, "KZT") });
  if (e.type !== "adjustment" || e.balance_delta_minor !== 0) {
    if (e.company_owes_me_delta_minor !== 0)
      items.push({ side: "own", label: "Компания должна мне", value: formatSigned(e.company_owes_me_delta_minor, "KZT") });
    if (e.i_owe_company_delta_minor !== 0)
      items.push({ side: "company", label: "Я должен компании", value: formatSigned(e.i_owe_company_delta_minor, "KZT") });
  } else {
    // Долговая корректировка: сумма уже в заголовке строки, здесь только чья сторона.
    if (e.company_owes_me_delta_minor !== 0) items.push({ side: "own", label: "Компания должна мне", value: "" });
    if (e.i_owe_company_delta_minor !== 0) items.push({ side: "company", label: "Я должен компании", value: "" });
  }
  if (items.length === 0) return null;
  return (
    <span className="entry__effects">
      {items.map((i) => (
        <span key={i.label} className="entry__effect">
          <span className={`swatch swatch--${i.side}`} aria-hidden="true" />
          {i.label} {i.value && <span className="amount">{i.value}</span>}
        </span>
      ))}
    </span>
  );
}
