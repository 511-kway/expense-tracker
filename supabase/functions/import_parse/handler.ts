// import_parse(file) → { filename, format, rows, errors }; GET ?template=<формат> отдаёт шаблон. (док 05, раздел 4; тикет 18). Разбирает
// загруженный CSV, xlsx, JSON (или zip экспорта) в строки импорта для RPC import_preview. В базу не
// пишет; суммы в строках модулем, целыми минимальными единицами строкой (без float).
// Ошибки файла целиком (нет колонок, не читается) приходят в `errors` с кодом 200: это ответ
// о содержимом файла, а не сбой запроса.
import { EXPORT_FORMATS, type ExportFormat } from "../export/format.ts";
import { parseImportFile } from "./parse.ts";
import { templateFile } from "./template.ts";

export type Deps = {
  /** Пользователь из заголовка Authorization разрешён (is_allowed, ADR-0007). */
  isAllowed(authorization: string | null): Promise<boolean>;
};

/** Больше файла не принимаем: 10 МиБ хватает на тысячи строк в любом формате. */
export const MAX_FILE_BYTES = 10 * 1024 * 1024;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Expose-Headers": "Content-Disposition",
};

const CONTENT_TYPES: Record<ExportFormat, string> = {
  csv: "text/csv; charset=utf-8",
  json: "application/json",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

export async function handleImportParse(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST" && req.method !== "GET") return json(405, { error: "method_not_allowed" });

  const authorization = req.headers.get("Authorization");
  if (!authorization || !(await deps.isAllowed(authorization))) return json(403, { error: "not_allowed" });

  // GET ?template=csv|xlsx|json: шаблон файла с примерами строк.
  if (req.method === "GET") {
    const format = new URL(req.url).searchParams.get("template") as ExportFormat;
    if (!EXPORT_FORMATS.includes(format)) return json(400, { error: "field_invalid", field: "template" });
    return new Response(await templateFile(format) as Uint8Array<ArrayBuffer>, {
      status: 200,
      headers: {
        ...CORS,
        "Content-Type": CONTENT_TYPES[format],
        "Content-Disposition": `attachment; filename="import_template.${format}"`,
      },
    });
  }

  let file: FormDataEntryValue | null;
  try {
    file = (await req.formData()).get("file");
  } catch {
    return json(400, { error: "field_invalid", field: "file" });
  }
  if (!(file instanceof File)) return json(400, { error: "field_invalid", field: "file" });
  if (file.size > MAX_FILE_BYTES) return json(413, { error: "file_too_large" });

  const result = await parseImportFile(file.name, new Uint8Array(await file.arrayBuffer()));
  return json(200, { filename: file.name, ...result });
}
