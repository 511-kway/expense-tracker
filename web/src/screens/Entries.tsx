import { useEffect, useState, type ReactNode } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatDate } from "../dates";
import {
  ENTRY_COLUMNS,
  SETTLEMENT_DIRECTIONS,
  TRANSFER_PURPOSES,
  adjustmentLabel,
  entryTitle,
  refundLabel,
  conversionLabel,
  formatSigned,
  type EntryRow,
} from "../entries";

/** Эти типы правятся в форме; остальные появятся со своими тикетами. */
export const EDITABLE = new Set([
  "expense",
  "income",
  "transfer",
  "company_topup",
  "company_advance_return",
  "settlement",
  "netting",
  "adjustment",
  "refund",
]);

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

/** Строка записи ленты; её же показывает список погашений на экране «Расчёт с компанией». */
export function EntryItem({ entry: e, onEdit }: { entry: EntryRow; onEdit?: () => void }) {
  // Перевод и взаимозачёт не меняют итог моих денег: сумма без знака, стороны в подписи и эффектах.
  // Черновик ещё ничего не сдвинул: сумма без знака.
  const amount =
    e.type === "transfer" || e.type === "netting" || e.status === "draft"
      ? formatMoney(e.amount_minor, e.currency)
      : e.balance_delta_minor !== 0
        ? // Остаток двигается в валюте счёта: тенговая карта списывает тенговый эквивалент.
          formatSigned(e.balance_delta_minor, e.account_currency ?? e.currency)
        : formatSigned(
            e.company_owes_me_delta_minor !== 0 ? e.company_owes_me_delta_minor : e.i_owe_company_delta_minor,
            "KZT",
          );
  const content: ReactNode = (
    <>
      <span className="entry__head">
        <span className="entry__title">{entryTitle(e)}</span>
        <span className="entry__amount amount">{amount}</span>
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
  if (e.type === "transfer") {
    parts.push(`с «${e.account_name ?? "счёта"}» на «${e.to_account_name ?? "счёт"}»`);
    if (e.transfer_purpose) parts.push(TRANSFER_PURPOSES[e.transfer_purpose].toLowerCase());
  } else if (e.account_name) parts.push(e.account_name);
  const conversion = conversionLabel(e);
  if (conversion) parts.push(conversion);
  if (e.type === "settlement" && e.settlement_direction)
    parts.push(SETTLEMENT_DIRECTIONS[e.settlement_direction].toLowerCase());
  if (e.type === "netting") parts.push("обе стороны долга, без движения денег");
  if (e.type === "adjustment") parts.push(adjustmentLabel(e));
  if (e.status === "draft") parts.unshift(e.source_pending ? "черновик, источник?" : "черновик");
  if (e.type === "expense") {
    if (e.status === "done" && !e.category_id) parts.push("без категории");
    if (e.purpose === "work") parts.push("работа");
    else parts.push(e.source === "company" ? "личное, деньгами компании" : "личное");
    if (e.refunded_minor > 0)
      parts.push(
        e.refunded_minor >= e.amount_minor ? "вернули полностью" : `вернули ${formatMoney(e.refunded_minor, e.currency)}`,
      );
  }
  if (e.type === "refund") parts.push(refundLabel(e));
  if (e.type === "income" && e.category_name) parts.push("поступление");
  if ((e.type === "company_topup" || e.type === "transfer") && e.fee_minor > 0)
    parts.push(`комиссия ${formatMoney(e.fee_minor, e.currency)}, ${e.fee_payer === "own" ? "платил я" : "платила компания"}`);
  if (e.comment) parts.push(e.comment);
  return parts.join(", ");
}

/** Что запись сделала с авансом и сторонами долга: цвет «свои» и «компания» плюс подпись. */
function Effects({ entry: e }: { entry: EntryRow }) {
  const items: { side: "own" | "company"; label: string; value: string }[] = [];
  // У перевода аванс двигается на двух счетах: подпись называет счёт.
  const from = e.type === "transfer" ? ` «${e.account_name ?? "откуда"}»` : "";
  if (e.advance_delta_minor < 0)
    items.push({ side: "company", label: `Из аванса${from}`, value: formatMoney(-e.advance_delta_minor, "KZT") });
  if (e.advance_delta_minor > 0)
    items.push({ side: "company", label: `В аванс${from}`, value: formatMoney(e.advance_delta_minor, "KZT") });
  if (e.type === "transfer" && e.to_advance_delta_minor !== 0)
    items.push({
      side: "company",
      label: `${e.to_advance_delta_minor > 0 ? "В аванс" : "Из аванса"} «${e.to_account_name ?? "куда"}»`,
      value: formatMoney(Math.abs(e.to_advance_delta_minor), "KZT"),
    });
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
