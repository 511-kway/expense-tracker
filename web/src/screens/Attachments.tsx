import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { errorText } from "../errors";
import { attachmentKind, fileProblem } from "../files";
import { removeFiles, signedUrls, uploadFile } from "../storage";

type AttachmentRow = {
  id: string;
  file_path: string;
  file_name: string | null;
  kind: "receipt" | "screenshot" | "invoice";
};

const KIND_LABEL: Record<AttachmentRow["kind"], string> = {
  receipt: "Чек",
  screenshot: "Скрин",
  invoice: "Счёт-фактура",
};

/** Загрузить файлы в папку записи и прикрепить (add_attachment). Сколько не получилось. */
export async function attachFiles(entryId: string, files: File[]): Promise<number> {
  let failed = 0;
  for (const file of files) {
    const up = await uploadFile(file, `entries/${entryId}`);
    if ("error" in up) {
      failed++;
      continue;
    }
    const { error } = await supabase.rpc("add_attachment", {
      p_entry_id: entryId,
      p_file_path: up.path,
      p_kind: attachmentKind(file.type),
      p_file_name: file.name,
    });
    if (error) {
      failed++;
      await removeFiles([up.path]);
    }
  }
  return failed;
}

/**
 * Вложения в форме записи (док 04, 4.2: скрытый блок «дополнительно»). У сохранённой записи файл
 * прикрепляется сразу; у новой ждёт в списке и прикрепится после сохранения (pending).
 */
export function AttachmentsBlock(props: {
  entryId?: string;
  pending: File[];
  onPending: (files: File[]) => void;
  /** Скрин заметки, который приложится к записи при разборе. */
  noteScreenshot?: boolean;
}) {
  const { entryId, pending } = props;
  const [rows, setRows] = useState<AttachmentRow[]>([]);
  const [urls, setUrls] = useState<Map<string, string>>(new Map());
  const [revision, setRevision] = useState(0);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  useEffect(() => {
    if (!entryId) return;
    let live = true;
    void (async () => {
      const { data, error } = await supabase
        .from("attachments")
        .select("id, file_path, file_name, kind")
        .eq("entry_id", entryId)
        .order("created_at");
      if (!live || error || !data) return;
      const list = data as AttachmentRow[];
      setRows(list);
      const signed = await signedUrls(list.map((r) => r.file_path));
      if (live) setUrls(signed);
    })();
    return () => {
      live = false;
    };
  }, [entryId, revision]);

  async function pick(files: FileList | null) {
    setFailure(null);
    const chosen = Array.from(files ?? []);
    const bad = chosen.map(fileProblem).find((p) => p !== null);
    if (bad) return setFailure(bad);
    if (!entryId) return props.onPending([...pending, ...chosen]);
    setBusy(true);
    const failed = await attachFiles(entryId, chosen);
    setBusy(false);
    if (failed > 0) setFailure("Не все файлы прикрепились. Попробуйте ещё раз.");
    setRevision((r) => r + 1);
  }

  async function detach(row: AttachmentRow) {
    setFailure(null);
    setBusy(true);
    const { data, error } = await supabase.rpc("delete_attachment", { p_attachment_id: row.id });
    setBusy(false);
    if (error) return setFailure(errorText(error));
    await removeFiles((data as { removed_files?: unknown }).removed_files);
    setRevision((r) => r + 1);
  }

  const count = rows.length + pending.length + (props.noteScreenshot ? 1 : 0);

  return (
    <details className="extra" open={count > 0 ? true : undefined}>
      <summary>Дополнительно: вложения{count > 0 ? ` (${count})` : ""}</summary>
      <div className="extra__body">
        {(rows.length > 0 || pending.length > 0 || props.noteScreenshot) && (
          <ul className="files">
            {props.noteScreenshot && (
              <li>
                <span>Скрин заметки</span>
                <span className="muted">приложится к записи</span>
              </li>
            )}
            {rows.map((r) => (
              <li key={r.id}>
                {urls.get(r.file_path) ? (
                  <a href={urls.get(r.file_path)} target="_blank" rel="noreferrer">
                    {r.file_name ?? KIND_LABEL[r.kind]}
                  </a>
                ) : (
                  <span>{r.file_name ?? KIND_LABEL[r.kind]}</span>
                )}
                <button className="button button--quiet" type="button" disabled={busy} onClick={() => void detach(r)}>
                  Открепить
                </button>
              </li>
            ))}
            {pending.map((f, i) => (
              <li key={`${f.name}:${i}`}>
                <span>{f.name}</span>
                <button
                  className="button button--quiet"
                  type="button"
                  onClick={() => props.onPending(pending.filter((_, j) => j !== i))}
                >
                  Убрать
                </button>
              </li>
            ))}
          </ul>
        )}
        <label className="button file-pick">
          {busy ? "Прикрепляем…" : "Приложить чек, скрин или PDF"}
          <input
            type="file"
            accept="image/*,application/pdf"
            multiple
            disabled={busy}
            onChange={(e) => {
              void pick(e.target.files);
              e.target.value = "";
            }}
          />
        </label>
        {!entryId && pending.length > 0 && <p className="field__hint">Файлы прикрепятся, когда вы сохраните запись.</p>}
        {failure && (
          <p className="error" role="alert">
            {failure}
          </p>
        )}
      </div>
    </details>
  );
}
