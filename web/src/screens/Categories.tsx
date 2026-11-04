import { useCallback, useEffect, useState, type FormEvent } from "react";
import { supabase } from "../supabase";
import { errorText } from "../errors";

export type CategoryRow = { id: string; name: string; is_archived: boolean };

/** Категории трат пользователя (чтение напрямую, по RLS). */
export function useCategories(): [CategoryRow[] | null | "error", () => Promise<void>] {
  const [rows, setRows] = useState<CategoryRow[] | null | "error">(null);
  const load = useCallback(async () => {
    const { data, error } = await supabase.from("categories").select("id, name, is_archived").order("name");
    setRows(error || !data ? "error" : (data as CategoryRow[]));
  }, []);
  useEffect(() => {
    void load();
  }, [load]);
  return [rows, load];
}

/** «Категории»: создать, переименовать, архивировать. Всё через RPC, название уникально. */
export function Categories() {
  const [rows, reload] = useCategories();
  const [name, setName] = useState("");
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function add(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    if (!name.trim()) return setFailure("Введите название категории.");
    setBusy(true);
    const { error } = await supabase.rpc("create_category", { p_name: name });
    setBusy(false);
    if (error) return setFailure(errorText(error));
    setName("");
    await reload();
  }

  if (rows === null) return <p className="muted" aria-busy="true">Загружаем категории…</p>;
  if (rows === "error")
    return (
      <p className="error" role="alert">
        Не получилось загрузить категории. Обновите страницу.
      </p>
    );

  const active = rows.filter((r) => !r.is_archived);
  const archived = rows.filter((r) => r.is_archived);

  return (
    <div className="categories">
      <form className="categories__add" onSubmit={add} noValidate>
        <div className="field">
          <label htmlFor="cat-new">Новая категория</label>
          <input id="cat-new" value={name} onChange={(e) => setName(e.target.value)} placeholder="Продукты" autoComplete="off" />
        </div>
        <button className="button button--primary" type="submit" disabled={busy}>
          Добавить категорию
        </button>
        {failure && (
          <p className="error" role="alert">
            {failure}
          </p>
        )}
      </form>

      {active.length === 0 ? (
        <p className="empty">Категорий пока нет. Добавьте первую: без категории трату не записать.</p>
      ) : (
        <ul className="categories__list">
          {active.map((c) => (
            <CategoryItem key={c.id} category={c} onChanged={reload} />
          ))}
        </ul>
      )}
      {archived.length > 0 && (
        <details className="accounts-archive">
          <summary>Архив: {archived.length}</summary>
          <ul className="categories__list">
            {archived.map((c) => (
              <CategoryItem key={c.id} category={c} onChanged={reload} />
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}

function CategoryItem({ category: c, onChanged }: { category: CategoryRow; onChanged: () => Promise<void> }) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(c.name);
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function run(rpc: string, args: Record<string, unknown>) {
    setFailure(null);
    setBusy(true);
    const { error } = await supabase.rpc(rpc, args);
    setBusy(false);
    if (error) {
      setFailure(errorText(error));
      return false;
    }
    await onChanged();
    return true;
  }

  async function rename(e: FormEvent) {
    e.preventDefault();
    if (!name.trim()) return setFailure("Введите название категории.");
    if (await run("rename_category", { p_category_id: c.id, p_name: name })) setEditing(false);
  }

  return (
    <li className="category">
      {editing ? (
        <form className="category__edit" onSubmit={rename} noValidate>
          <div className="field">
            <label htmlFor={`cat-${c.id}`}>Название</label>
            <input id={`cat-${c.id}`} value={name} onChange={(e) => setName(e.target.value)} autoComplete="off" autoFocus />
          </div>
          <div className="category__actions">
            <button className="button button--primary" type="submit" disabled={busy}>
              Сохранить
            </button>
            <button
              className="button button--quiet"
              type="button"
              onClick={() => {
                setEditing(false);
                setName(c.name);
                setFailure(null);
              }}
            >
              Отмена
            </button>
          </div>
        </form>
      ) : (
        <div className="category__row">
          <span className="category__name">{c.name}</span>
          <span className="category__actions">
            <button className="button button--quiet" type="button" onClick={() => setEditing(true)}>
              Переименовать
            </button>
            <button
              className="button button--quiet"
              type="button"
              disabled={busy}
              onClick={() => void run(c.is_archived ? "unarchive_category" : "archive_category", { p_category_id: c.id })}
            >
              {c.is_archived ? "Вернуть" : "В архив"}
            </button>
          </span>
        </div>
      )}
      {failure && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </li>
  );
}
