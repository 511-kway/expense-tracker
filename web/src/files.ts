/**
 * Файлы заметок и вложений (тикет 16). Бакет `files` приватный, путь `<user_id>/...`: политики
 * Storage пускают только в свою папку. Лимиты те же, что у бакета, здесь только чтобы сказать
 * понятно до загрузки.
 */
export const FILE_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "image/heif",
  "image/gif",
  "application/pdf",
] as const;

export const MAX_FILE_BYTES = 20 * 1024 * 1024;

/** Что не так с файлом для бакета, или null. */
export function fileProblem(file: { type: string; size: number }): string | null {
  if (!(FILE_TYPES as readonly string[]).includes(file.type))
    return "Можно приложить картинку (JPG, PNG, HEIC, WebP, GIF) или PDF.";
  if (file.size > MAX_FILE_BYTES) return "Файл больше 20 МБ: сожмите его или сделайте скрин.";
  return null;
}

const EXT_BY_TYPE: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/heic": "heic",
  "image/heif": "heif",
  "image/gif": "gif",
  "application/pdf": "pdf",
};

/** Путь в бакете: своя папка, подпапка (notes или entries/<id>), случайное имя, расширение. */
export function storagePath(userId: string, folder: string, file: { name: string; type: string }, id: string): string {
  const fromName = /\.([a-z0-9]{1,5})$/i.exec(file.name)?.[1]?.toLowerCase();
  const ext = fromName === "jpeg" ? "jpg" : (fromName ?? EXT_BY_TYPE[file.type] ?? "bin");
  return `${userId}/${folder}/${id}.${ext}`;
}

/** Вид вложения по типу файла: PDF это invoice, картинка это чек. */
export function attachmentKind(type: string): "receipt" | "invoice" {
  return type === "application/pdf" ? "invoice" : "receipt";
}

const TITLE_MAX = 80;

/** Предзаполнение полной формы из заметки: первая строка в название, вся заметка в комментарий. */
export function notePrefill(text: string | null): { title: string; comment: string } {
  const comment = (text ?? "").trim();
  const first = comment.split("\n")[0]!.trim();
  const title = first.length > TITLE_MAX ? first.slice(0, TITLE_MAX - 1) + "…" : first;
  return { title, comment };
}
