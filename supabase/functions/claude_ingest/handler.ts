// claude_ingest (док 05): вход для Claude Code. Служебный токен приходит в заголовке
// X-Claude-Token (или Authorization: Bearer etk_…), функция считает его SHA-256 и передаёт базе
// только хэш. RPC claude_ingest находит владельца по хэшу и создаёт запись под ним той же функцией,
// что экран (create_entry / convert_note_to_entry / quick_capture): та же проверка, движок,
// пересчёт и лист ожидания. id пользователя из тела не берётся: в базу уходят только action,
// payload, note_id. Ошибки приходят кодами дока 05 ({ok: false, error, details}).
// Зависимости (RPC и подписанные ссылки Storage) приходят снаружи: index.ts даёт настоящие, тесты подделки.

/** Ответ RPC claude_ingest как есть. */
export type IngestResult = { ok: boolean; error?: string; details?: unknown; [key: string]: unknown };

export type Deps = {
  /** RPC claude_ingest(p_token_hash, p_request) ключом service_role. */
  ingest(tokenHash: string, request: Record<string, unknown>): Promise<IngestResult>;
  /** Короткая подписанная ссылка на файл заметки в Storage (путь от адреса API) или null. */
  signedUrl(path: string): Promise<string | null>;
};

/** Запись это пара килобайт JSON; больше 64 КиБ не нужно никогда. */
export const MAX_BODY_BYTES = 64 * 1024;

const ACTIONS = new Set(["create_entry", "convert_note", "quick_capture", "context"]);
const TOKEN_FORMAT = /^etk_[A-Za-z0-9_-]{43}$/;

const STATUS: Record<string, number> = {
  token_invalid: 401,
  not_allowed: 403,
  rate_limited: 429,
  field_invalid: 400,
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function fail(status: number, error: string, details?: unknown): Response {
  return json(status, details === undefined ? { ok: false, error } : { ok: false, error, details });
}

function tokenFrom(req: Request): string | null {
  const header = req.headers.get("X-Claude-Token")?.trim();
  const bearer = req.headers.get("Authorization")?.match(/^Bearer\s+(etk_\S+)$/)?.[1];
  const token = header || bearer;
  return token && TOKEN_FORMAT.test(token) ? token : null;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Тело не больше лимита: по Content-Length сразу, иначе читаем поток и обрываем на лимите. */
async function readBody(req: Request): Promise<string | null> {
  const declared = Number(req.headers.get("Content-Length") ?? "0");
  if (declared > MAX_BODY_BYTES) return null;
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(all);
}

type Note = { attachment_path: string | null; [key: string]: unknown };

export async function handleClaudeIngest(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return fail(405, "method_not_allowed");

  const token = tokenFrom(req);
  if (!token) return fail(401, "token_invalid");

  const text = await readBody(req);
  if (text === null) return fail(413, "payload_too_large");

  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return fail(400, "field_invalid", { field: "body" });
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return fail(400, "field_invalid", { field: "body" });
  }
  const { action, payload, note_id } = body as Record<string, unknown>;
  if (typeof action !== "string" || !ACTIONS.has(action)) return fail(400, "field_invalid", { field: "action" });

  const request: Record<string, unknown> = { action };
  if (note_id !== undefined) request.note_id = note_id;
  if (payload !== undefined) request.payload = payload;

  let result: IngestResult;
  try {
    result = await deps.ingest(await sha256Hex(token), request);
  } catch (error) {
    console.error("claude_ingest: database call failed", error);
    return fail(502, "server_unavailable");
  }

  if (!result.ok) return fail(STATUS[result.error ?? ""] ?? 422, result.error ?? "unknown", result.details);

  if (action === "context" && Array.isArray(result.notes)) {
    result.notes = await Promise.all(
      (result.notes as Note[]).map(async (n) => ({
        ...n,
        attachment_url: n.attachment_path ? await deps.signedUrl(n.attachment_path) : null,
      })),
    );
  }
  return json(200, result);
}
