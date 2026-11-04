import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatDate } from "../dates";
import { ENTRY_COLUMNS, entryTitle, type EntryRow } from "../entries";

/** Строка v_inbox: что ждёт внимания (тикет 16 добавит новые заметки, kind = "note"). */
type InboxRow = {
  kind: "draft" | "no_category";
  entry_id: string;
  occurred_on: string;
  amount_minor: number;
  currency: string;
  account_name: string | null;
  purpose: "personal" | "work" | null;
  title: string | null;
  source_pending: boolean;
};

/** Число элементов инбокса для бейджа: считает сервер (v_inbox_count). Обновляется с revision. */
export function useInboxCount(revision: number): number {
  const [count, setCount] = useState(0);
  useEffect(() => {
    let live = true;
    void (async () => {
      const { data, error } = await supabase.from("v_inbox_count").select("items").single();
      if (live && !error && data) setCount((data as { items: number }).items);
    })();
    return () => {
      live = false;
    };
  }, [revision]);
  return count;
}

/**
 * Инбокс (док 04, раздел 5): черновики быстрого ввода и учтённые траты без категории. Черновик
 * с «источник?» подсвечен; строка открывает полную форму: у черновика «Учесть трату»
 * (promote_draft), у траты без категории обычная правка.
 */
export function Inbox({ onOpen, onCapture }: { onOpen: (entry: EntryRow) => void; onCapture: () => void }) {
  const [rows, setRows] = useState<{ item: InboxRow; entry: EntryRow }[] | null | "error">(null);

  useEffect(() => {
    void (async () => {
      const inbox = await supabase
        .from("v_inbox")
        .select("kind, entry_id, occurred_on, amount_minor, currency, account_name, purpose, title, source_pending")
        .order("kind", { ascending: true })
        .order("occurred_on", { ascending: false })
        .order("created_at", { ascending: false });
      if (inbox.error || !inbox.data) return setRows("error");
      const items = inbox.data as InboxRow[];
      if (items.length === 0) return setRows([]);
      const entries = await supabase
        .from("v_entries")
        .select(ENTRY_COLUMNS)
        .in(
          "entry_id",
          items.map((i) => i.entry_id),
        );
      if (entries.error || !entries.data) return setRows("error");
      const byId = new Map((entries.data as unknown as EntryRow[]).map((e) => [e.entry_id, e]));
      setRows(items.flatMap((item) => (byId.has(item.entry_id) ? [{ item, entry: byId.get(item.entry_id)! }] : [])));
    })();
  }, []);

  if (rows === null) return <p className="muted" aria-busy="true">Загружаем инбокс…</p>;
  if (rows === "error")
    return (
      <p className="error" role="alert">
        Не получилось загрузить инбокс. Обновите страницу.
      </p>
    );
  if (rows.length === 0)
    return (
      <div className="empty">
        <p>Инбокс пуст: черновиков и трат без категории нет. Быстрый ввод запишет трату за пару секунд.</p>
        <button className="button button--primary" type="button" onClick={onCapture}>
          Записать трату
        </button>
      </div>
    );

  return (
    <ul className="feed__list inbox">
      {rows.map(({ item, entry }) => (
        <li key={item.entry_id}>
          <button
            className={`entry${item.source_pending ? " inbox__item--source" : ""}`}
            type="button"
            onClick={() => onOpen(entry)}
            aria-label={`${entryTitle(entry)}: ${item.kind === "draft" ? "учесть черновик" : "выбрать категорию"}`}
          >
            <span className="entry__head">
              <span className="entry__title">{entryTitle(entry)}</span>
              <span className="entry__amount amount">{formatMoney(item.amount_minor, item.currency)}</span>
            </span>
            <span className="entry__meta muted">
              {[
                formatDate(item.occurred_on),
                item.account_name,
                item.purpose === "work" ? "работа" : entry.source === "company" ? "личное, деньгами компании" : "личное",
              ]
                .filter(Boolean)
                .join(", ")}
            </span>
            <span className={`inbox__mark inbox__mark--${item.source_pending ? "source" : item.kind}`}>
              {item.source_pending ? "источник?" : item.kind === "draft" ? "черновик" : "без категории"}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}
