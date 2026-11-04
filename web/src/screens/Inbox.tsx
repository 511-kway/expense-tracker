import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatDate } from "../dates";
import { ENTRY_COLUMNS, entryTitle, type EntryRow } from "../entries";
import { notePrefill } from "../files";
import { noteTime, type NoteRow } from "./Notes";

/** Строка v_inbox: что ждёт внимания. У заметки (kind = "note") нет записи, только note_*. */
type InboxRow = {
  kind: "draft" | "no_category" | "note";
  entry_id: string | null;
  occurred_on: string;
  amount_minor: number;
  currency: string;
  account_name: string | null;
  purpose: "personal" | "work" | null;
  title: string | null;
  source_pending: boolean;
  created_at: string;
  note_id: string | null;
  note_text: string | null;
  note_attachment_path: string | null;
};

type Item = { kind: "entry"; item: InboxRow; entry: EntryRow } | { kind: "note"; note: NoteRow };

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
 * Инбокс (док 04, раздел 5): черновики быстрого ввода, учтённые траты без категории и новые
 * заметки. Черновик с «источник?» подсвечен; строка открывает полную форму: у черновика «Учесть
 * трату» (promote_draft), у траты без категории обычная правка, у заметки новая запись из неё.
 */
export function Inbox({
  onOpen,
  onOpenNote,
  onCapture,
}: {
  onOpen: (entry: EntryRow) => void;
  onOpenNote: (note: NoteRow) => void;
  onCapture: () => void;
}) {
  const [rows, setRows] = useState<Item[] | null | "error">(null);

  useEffect(() => {
    void (async () => {
      const inbox = await supabase
        .from("v_inbox")
        .select(
          "kind, entry_id, occurred_on, amount_minor, currency, account_name, purpose, title, source_pending, created_at, note_id, note_text, note_attachment_path",
        )
        .order("kind", { ascending: true })
        .order("occurred_on", { ascending: false })
        .order("created_at", { ascending: false });
      if (inbox.error || !inbox.data) return setRows("error");
      const items = inbox.data as InboxRow[];
      const ids = items.flatMap((i) => (i.entry_id ? [i.entry_id] : []));
      let byId = new Map<string, EntryRow>();
      if (ids.length > 0) {
        const entries = await supabase.from("v_entries").select(ENTRY_COLUMNS).in("entry_id", ids);
        if (entries.error || !entries.data) return setRows("error");
        byId = new Map((entries.data as unknown as EntryRow[]).map((e) => [e.entry_id, e]));
      }
      setRows(
        items.flatMap((item): Item[] => {
          if (item.kind === "note" && item.note_id)
            return [
              {
                kind: "note",
                note: {
                  id: item.note_id,
                  text: item.note_text,
                  attachment_path: item.note_attachment_path,
                  status: "new",
                  linked_entry_id: null,
                  created_at: item.created_at,
                },
              },
            ];
          const entry = item.entry_id ? byId.get(item.entry_id) : undefined;
          return entry ? [{ kind: "entry", item, entry }] : [];
        }),
      );
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
        <p>Инбокс пуст: черновиков, трат без категории и новых заметок нет. Быстрый ввод запишет трату за пару секунд.</p>
        <button className="button button--primary" type="button" onClick={onCapture}>
          Записать трату
        </button>
      </div>
    );

  return (
    <ul className="feed__list inbox">
      {rows.map((row) => {
        if (row.kind === "note") {
          const { note } = row;
          const title = notePrefill(note.text).title || "Скрин без текста";
          return (
            <li key={`note:${note.id}`}>
              <button
                className="entry"
                type="button"
                onClick={() => onOpenNote(note)}
                aria-label={`Заметка «${title}»: сделать запись`}
              >
                <span className="entry__head">
                  <span className="entry__title">{title}</span>
                </span>
                <span className="entry__meta muted">
                  {[noteTime(note.created_at), note.attachment_path ? "со скрином" : null]
                    .filter(Boolean)
                    .join(", ")}
                </span>
                <span className="inbox__mark inbox__mark--note">заметка</span>
              </button>
            </li>
          );
        }
        const { item, entry } = row;
        return (
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
        );
      })}
    </ul>
  );
}
