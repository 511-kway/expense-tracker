import { supabase } from "./supabase";
import { fileProblem, storagePath } from "./files";

/** Приватный бакет файлов (миграция тикета 16): своя папка, только разрешённому. */
const BUCKET = "files";

/** Загрузить файл в свою папку; путь или текст ошибки. */
export async function uploadFile(file: File, folder: string): Promise<{ path: string } | { error: string }> {
  const problem = fileProblem(file);
  if (problem) return { error: problem };
  const { data } = await supabase.auth.getSession();
  const userId = data.session?.user.id;
  if (!userId) return { error: "Сессия закончилась: войдите снова." };
  const path = storagePath(userId, folder, file, crypto.randomUUID());
  const { error } = await supabase.storage.from(BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (error) return { error: "Не получилось загрузить файл. Попробуйте ещё раз." };
  return { path };
}

/**
 * Удалить файлы, которые сервер вернул в removed_files (SQL удалить объект Storage не может).
 * Не получилось: файлы подчистит sweepOrphanFiles позже, на экране это не ошибка.
 */
export async function removeFiles(paths: unknown): Promise<void> {
  const list = Array.isArray(paths) ? paths.filter((p): p is string => typeof p === "string") : [];
  if (list.length > 0) await supabase.storage.from(BUCKET).remove(list);
}

/** Подчистка: свои файлы без заметки и вложения старше суток (v_orphan_files). */
export async function sweepOrphanFiles(): Promise<void> {
  const { data, error } = await supabase.from("v_orphan_files").select("name").limit(100);
  if (!error && data) await removeFiles(data.map((r) => (r as { name: string }).name));
}

/** Ссылки на просмотр приватных файлов на час, по пути. */
export async function signedUrls(paths: string[]): Promise<Map<string, string>> {
  if (paths.length === 0) return new Map();
  const { data } = await supabase.storage.from(BUCKET).createSignedUrls(paths, 3600);
  return new Map((data ?? []).flatMap((d) => (d.path && d.signedUrl ? [[d.path, d.signedUrl] as [string, string]] : [])));
}
