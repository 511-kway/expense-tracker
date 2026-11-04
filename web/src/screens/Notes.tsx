import { useEffect, useState, type FormEvent } from "react";
import { supabase } from "../supabase";
import { errorText } from "../errors";
import { formatMoney } from "../money";
import { formatDate } from "../dates";
import { fileProblem } from "../files";
import { removeFiles, signedUrls, sweepOrphanFiles, uploadFile } from "../storage";
import { ENTRY_COLUMNS, entryTitle, type EntryRow } from "../entries";

/** Заметка (док 02, раздел 6): текст и/или скрин, новая или разобранная со ссылкой на запись. */
export type NoteRow = {
  id: string;
  text: string | null;
  attachment_path: string | null;
  status: "new" | "processed";
  linked_entry_id: string | null;
  created_at: string;
};

const NOTE_COLUMNS = "id, text, attachment_path, status, linked_entry_id, created_at";

export function noteTime(createdAt: string): string {
  const d = new Date(createdAt);
  const day = new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Almaty" }).format(d);
  const time = new Intl.DateTimeFormat("ru-RU", { timeZone: "Asia/Almaty", hour: "2-digit", minute: "2-digit" }).format(d);
  return `${formatDate(day)}, ${time}`;
}

/** Ссылка на просмотр скрина заметки (бакет приватный, ссылка на час). */
function useSignedUrl(path: string | null): string | null {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    if (!path) return;
    let live = true;
    void signedUrls([path]).then((m) => {
      if (live) setUrl(m.get(path) ?? null);
    });
    return () => {
      live = false;
    };
  }, [path]);
  return url;
}

/** Содержимое заметки: текст как написали и скрин, по нажатию открывается целиком. */
export function NoteCard({ note }: { note: Pick<NoteRow, "text" | "attachment_path" | "created_at"> }) {
  const url = useSignedUrl(note.attachment_path);
  return (
    <div className="note">
      <span className="note__time muted">{noteTime(note.created_at)}</span>
      {note.text && <p className="note__text">{note.text}</p>}
      {note.attachment_path &&
        (url ? (
          <a className="note__shot" href={url} target="_blank" rel="noreferrer" aria-label="Открыть скрин целиком">
            <img src={url} alt="Скрин заметки" loading="lazy" />
          </a>
        ) : (
          <span className="note__shot note__shot--loading muted">Скрин загружается…</span>
        ))}
    </div>
  );
}

/**
 * Новая заметка (док 04, 4.1, режим 3): текст и/или скрин или фото. На телефоне выбор файла
 * предлагает камеру. Скрин загружается в свою папку, затем create_note; не вышло = файл удаляется.
 */
export function NoteComposer({ onSaved }: { onSaved: () => void }) {
  const [text, setText] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  useEffect(() => {
    if (!file) return setPreview(null);
    const url = URL.createObjectURL(file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [file]);

  function pick(f: File | undefined) {
    setFailure(null);
    if (!f) return;
    const problem = fileProblem(f);
    if (problem || f.type === "application/pdf") return setFailure(problem ?? "К заметке прикладывается картинка: скрин или фото.");
    setFile(f);
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    if (!text.trim() && !file) return setFailure("Напишите текст или приложите скрин.");
    setBusy(true);
    let path: string | null = null;
    if (file) {
      const up = await uploadFile(file, "notes");
      if ("error" in up) {
        setBusy(false);
        return setFailure(up.error);
      }
      path = up.path;
    }
    const { error } = await supabase.rpc("create_note", { p_text: text, p_attachment_path: path });
    setBusy(false);
    if (error) {
      if (path) await removeFiles([path]);
      return setFailure(errorText(error));
    }
    setText("");
    setFile(null);
    onSaved();
  }

  return (
    <form className="account-form note-form" onSubmit={submit} noValidate>
      <div className="field">
        <label htmlFor="note-text">Что запомнить</label>
        <textarea
          id="note-text"
          rows={3}
          placeholder="Например, такси 2 500 с Kaspi, разобрать вечером"
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
      </div>
      {preview && file ? (
        <div className="note-form__shot">
          <img src={preview} alt="Выбранный скрин" />
          <button className="button button--quiet" type="button" onClick={() => setFile(null)}>
            Убрать скрин
          </button>
        </div>
      ) : (
        <label className="button file-pick">
          Приложить скрин или фото
          <input type="file" accept="image/*" onChange={(e) => {
            pick(e.target.files?.[0]);
            e.target.value = "";
          }} />
        </label>
      )}
      <p className="field__hint">Заметка не запись: остаток, аванс и долг она не меняет. Разберёте её позже из инбокса.</p>
      <div className="account-form__actions">
        <button className="button button--primary" type="submit" disabled={busy}>
          {busy ? "Сохраняем…" : "Сохранить заметку"}
        </button>
        {failure && (
          <p className="error" role="alert">
            {failure}
          </p>
        )}
      </div>
    </form>
  );
}

/**
 * Экран «Заметки» (док 04, раздел 6): новые и разобранные. Новую можно разобрать (полная форма с
 * предзаполнением) или удалить; у разобранной ссылка на запись.
 */
export function Notes(props: {
  onProcess: (note: NoteRow) => void;
  onOpenEntry: (entry: EntryRow) => void;
}) {
  const [filter, setFilter] = useState<"new" | "processed">("new");
  const [notes, setNotes] = useState<NoteRow[] | null | "error">(null);
  const [entries, setEntries] = useState<Map<string, EntryRow>>(new Map());
  const [revision, setRevision] = useState(0);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);

  useEffect(() => {
    void sweepOrphanFiles();
  }, []);

  useEffect(() => {
    void (async () => {
      const { data, error } = await supabase.from("notes").select(NOTE_COLUMNS).order("created_at", { ascending: false });
      if (error || !data) return setNotes("error");
      const list = data as NoteRow[];
      const linked = list.flatMap((n) => (n.linked_entry_id ? [n.linked_entry_id] : []));
      if (linked.length > 0) {
        const e = await supabase.from("v_entries").select(ENTRY_COLUMNS).in("entry_id", linked);
        if (!e.error && e.data)
          setEntries(new Map((e.data as unknown as EntryRow[]).map((row) => [row.entry_id, row])));
      }
      setNotes(list);
    })();
  }, [revision]);

  async function remove(note: NoteRow) {
    if (confirm !== note.id) return setConfirm(note.id);
    setFailure(null);
    const { data, error } = await supabase.rpc("delete_note", { p_note_id: note.id });
    setConfirm(null);
    if (error) return setFailure(errorText(error));
    await removeFiles((data as { removed_files?: unknown }).removed_files);
    setRevision((r) => r + 1);
  }

  if (notes === null) return <p className="muted" aria-busy="true">Загружаем заметки…</p>;
  if (notes === "error")
    return (
      <p className="error" role="alert">
        Не получилось загрузить заметки. Обновите страницу.
      </p>
    );

  const fresh = notes.filter((n) => n.status === "new");
  const done = notes.filter((n) => n.status === "processed");
  const shown = filter === "new" ? fresh : done;

  return (
    <div className="notes-screen">
      <NoteComposer onSaved={() => setRevision((r) => r + 1)} />

      <div className="segmented" role="group" aria-label="Какие заметки показать">
        <button type="button" aria-pressed={filter === "new"} onClick={() => setFilter("new")}>
          Новые <span className="segmented__count">{fresh.length}</span>
        </button>
        <button type="button" aria-pressed={filter === "processed"} onClick={() => setFilter("processed")}>
          Разобранные <span className="segmented__count">{done.length}</span>
        </button>
      </div>

      {failure && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}

      {shown.length === 0 ? (
        <p className="empty">
          {filter === "new"
            ? "Новых заметок нет. Запишите мысль или скрин выше, разберёте потом."
            : "Разобранных заметок пока нет. Из новой заметки сделайте запись, и она появится здесь со ссылкой."}
        </p>
      ) : (
        <ul className="notes">
          {shown.map((note) => {
            const entry = note.linked_entry_id ? entries.get(note.linked_entry_id) : undefined;
            return (
              <li key={note.id} className={`notes__item notes__item--${note.status}`}>
                <NoteCard note={note} />
                <div className="notes__actions">
                  {note.status === "new" ? (
                    <>
                      <button className="button button--primary" type="button" onClick={() => props.onProcess(note)}>
                        Сделать запись
                      </button>
                      <button className="button button--quiet" type="button" onClick={() => void remove(note)}>
                        {confirm === note.id ? "Точно удалить заметку" : "Удалить"}
                      </button>
                    </>
                  ) : entry ? (
                    <button className="notes__link" type="button" onClick={() => props.onOpenEntry(entry)}>
                      <span>Запись: {entryTitle(entry)}</span>
                      <span className="amount">{formatMoney(entry.amount_minor, entry.currency)}</span>
                      <span className="muted">{formatDate(entry.occurred_on)}</span>
                    </button>
                  ) : (
                    <span className="muted">Запись загружается…</span>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
