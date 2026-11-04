// Файл импорта → строки импорта (док 04, раздел 8; тикет 18). Читает CSV, JSON и xlsx по схеме
// файла `expenses` (ENTRY_COLUMNS) и превращает каждую строку функцией importRow из общей схемы,
// той же, по которой пишет экспорт. Суммы нигде не проходят через float: CSV даёт текст, JSON
// читается своим разборщиком, который оставляет у чисел исходный текст, xlsx читает
// read-excel-file (MIT, чистый JS на fflate и saxen) с parseNumber, отдающим текст ячейки.
// Принимает и сам zip экспорта: из него берётся файл `expenses.*`.
import readXlsxFile from "npm:read-excel-file@9.3.12/universal";
import { unzipSync } from "npm:fflate@0.8.2";
import { ENTRY_COLUMNS, type FileCell, type ImportRow, importRow } from "../_shared/schema.ts";

export type ImportFormat = "csv" | "xlsx" | "json";

/** Ошибка файла целиком: строки не разбираются. */
export type FileError = { code: string; columns?: string[]; limit?: number };

export type ParseResult = { format: ImportFormat | null; rows: ImportRow[]; errors: FileError[] };

/** Без этих колонок строки не прочитать; остальные колонки схемы можно опустить (пусто). */
export const REQUIRED_COLUMNS = ["occurred_on", "type", "amount"] as const;

/** Больше строк за раз не принимаем: предпросмотр проверяет каждую в одной транзакции. */
export const MAX_ROWS = 5000;

/** Строка таблицы: номер строки в файле и ячейки по порядку колонок шапки. */
type Table = { header: string[]; rows: { line: number; cells: FileCell[] }[] };

class FileInvalid extends Error {}

function formatOf(name: string): ImportFormat | "zip" | null {
  const ext = /\.([a-z0-9]+)$/i.exec(name)?.[1]?.toLowerCase();
  return ext === "csv" || ext === "xlsx" || ext === "json" || ext === "zip" ? ext : null;
}

// --- CSV (RFC 4180: запятая, кавычки, CRLF или LF, BOM в начале пропускается) ---

function readCsv(bytes: Uint8Array): Table {
  let text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (text.startsWith("﻿")) text = text.slice(1);
  const records: { line: number; cells: string[] }[] = [];
  let cells: string[] = [];
  let field = "";
  let quoted = false;
  let line = 1;
  let recordLine = 1;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (ch === '"') {
        quoted = false;
      } else {
        if (ch === "\n") line++;
        field += ch;
      }
    } else if (ch === '"' && field === "") {
      quoted = true;
    } else if (ch === ",") {
      cells.push(field);
      field = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      cells.push(field);
      records.push({ line: recordLine, cells });
      cells = [];
      field = "";
      line++;
      recordLine = line;
    } else {
      field += ch;
    }
  }
  if (quoted) throw new FileInvalid("unterminated quote");
  if (field !== "" || cells.length > 0) {
    cells.push(field);
    records.push({ line: recordLine, cells });
  }
  const [head, ...rest] = records;
  return { header: head?.cells ?? [], rows: rest };
}

// --- JSON: массив объектов; у чисел остаётся исходный текст ---

/** Число JSON исходным текстом. */
class JsonNumber {
  constructor(readonly text: string) {}
}

type JsonValue = string | boolean | null | JsonNumber | JsonValue[] | { [key: string]: JsonValue };

function parseJsonKeepingNumbers(text: string): JsonValue {
  let i = 0;
  const ws = () => {
    while (i < text.length && " \t\r\n".includes(text[i]!)) i++;
  };
  const fail = (): never => {
    throw new FileInvalid(`bad JSON at ${i}`);
  };
  const value = (): JsonValue => {
    ws();
    const ch = text[i];
    if (ch === "{") {
      i++;
      const obj: { [key: string]: JsonValue } = {};
      ws();
      if (text[i] === "}") return i++, obj;
      for (;;) {
        ws();
        if (text[i] !== '"') fail();
        const key = string();
        ws();
        if (text[i++] !== ":") fail();
        obj[key] = value();
        ws();
        if (text[i] === ",") i++;
        else if (text[i] === "}") return i++, obj;
        else fail();
      }
    }
    if (ch === "[") {
      i++;
      const arr: JsonValue[] = [];
      ws();
      if (text[i] === "]") return i++, arr;
      for (;;) {
        arr.push(value());
        ws();
        if (text[i] === ",") i++;
        else if (text[i] === "]") return i++, arr;
        else fail();
      }
    }
    if (ch === '"') return string();
    for (const [word, v] of [["true", true], ["false", false], ["null", null]] as const) {
      if (text.startsWith(word, i)) return i += word.length, v;
    }
    const num = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(text.slice(i, i + 400));
    if (!num) fail();
    i += num![0].length;
    return new JsonNumber(num![0]);
  };
  const string = (): string => {
    const start = i;
    i++;
    let escaped = false;
    for (; i < text.length; i++) {
      if (escaped) escaped = false;
      else if (text[i] === "\\") escaped = true;
      else if (text[i] === '"') break;
    }
    if (i >= text.length) fail();
    i++;
    try {
      return JSON.parse(text.slice(start, i));
    } catch {
      return fail();
    }
  };
  const result = value();
  ws();
  if (i !== text.length) fail();
  return result;
}

function readJson(bytes: Uint8Array): Table {
  let text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (text.startsWith("﻿")) text = text.slice(1);
  const data = parseJsonKeepingNumbers(text);
  if (!Array.isArray(data)) throw new FileInvalid("not an array");
  const header: string[] = [];
  for (const item of data) {
    if (item === null || typeof item !== "object" || Array.isArray(item) || item instanceof JsonNumber) {
      throw new FileInvalid("not an object");
    }
    for (const key of Object.keys(item)) if (!header.includes(key)) header.push(key);
  }
  const rows = data.map((item, index) => {
    const obj = item as { [key: string]: JsonValue };
    const cells = header.map((key): FileCell => {
      const v = obj[key];
      if (v === undefined || v === null || typeof v === "string" || typeof v === "boolean") return v ?? null;
      if (v instanceof JsonNumber) return v.text;
      throw new FileInvalid(`nested value in ${key}`);
    });
    return { line: index + 1, cells };
  });
  return { header, rows };
}

// --- xlsx ---

/**
 * Текст числовой ячейки xlsx → десятичная запись, как её показывает Excel: 15 значащих цифр,
 * половина от нуля, без хвостовых нулей. Excel хранит double и иногда пишет его 17 цифрами
 * (`1234.5599999999999` вместо `1234.56`); строковое округление до 15 цифр возвращает задуманное
 * число без float. Поэтому сумма в xlsx точна до 15 значащих цифр (13 цифр целой части с копейками).
 */
export function excelNumber(raw: string): string {
  const match = /^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(raw.trim());
  if (!match || (match[2] === "" && !match[3])) return raw.trim();
  const negative = match[1] === "-";
  let digits = (match[2] ?? "") + (match[3] ?? "");
  // value = digits × 10^exp
  let exp = Number(match[4] ?? 0) - (match[3] ?? "").length;
  const lead = digits.search(/[1-9]/);
  if (lead === -1) return "0";
  digits = digits.slice(lead);
  if (digits.length > 15) {
    const drop = digits.length - 15;
    let kept = digits.slice(0, 15);
    if (digits[15]! >= "5") kept = (BigInt(kept) + 1n).toString();
    exp += drop;
    digits = kept;
  }
  digits = digits.replace(/0+$/, (zeros) => {
    exp += zeros.length;
    return "";
  }) || "0";
  let text: string;
  if (exp >= 0) {
    text = digits + "0".repeat(exp);
  } else {
    const padded = digits.padStart(-exp + 1, "0");
    text = `${padded.slice(0, exp)}.${padded.slice(exp)}`;
  }
  return negative && text !== "0" ? `-${text}` : text;
}

function isoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

async function readXlsx(bytes: Uint8Array): Promise<Table> {
  let sheets: { sheet: string; data: unknown[][] }[];
  try {
    sheets = await readXlsxFile(new Blob([bytes as Uint8Array<ArrayBuffer>]), {
      parseNumber: (text: string) => ({ number: text }),
    } as never) as unknown as { sheet: string; data: unknown[][] }[];
  } catch {
    throw new FileInvalid("not an xlsx");
  }
  const first = sheets.find((s) => s.sheet === "expenses") ?? sheets[0];
  const [head = [], ...rest] = first?.data ?? [];
  const cell = (v: unknown): FileCell => {
    if (v === null || v === undefined) return null;
    if (typeof v === "string" || typeof v === "boolean") return v;
    if (v instanceof Date) return isoDate(v);
    if (typeof v === "object" && typeof (v as { number?: unknown }).number === "string") {
      return excelNumber((v as { number: string }).number);
    }
    return String(v);
  };
  return {
    header: head.map((v) => String(cell(v) ?? "")),
    rows: rest.map((row, index) => ({ line: index + 2, cells: row.map(cell) })),
  };
}

// --- общее ---

async function readTable(format: ImportFormat, bytes: Uint8Array): Promise<Table> {
  try {
    switch (format) {
      case "csv":
        return readCsv(bytes);
      case "json":
        return readJson(bytes);
      case "xlsx":
        return await readXlsx(bytes);
    }
  } catch (error) {
    if (error instanceof FileInvalid || error instanceof TypeError || error instanceof SyntaxError) {
      throw new FileInvalid(String(error));
    }
    throw error;
  }
}

function fail(format: ImportFormat | null, error: FileError): ParseResult {
  return { format, rows: [], errors: [error] };
}

/** Файл (имя для формата, байты) → строки импорта с ошибками по строкам или ошибка файла. */
export async function parseImportFile(name: string, bytes: Uint8Array): Promise<ParseResult> {
  let format = formatOf(name);
  if (format === "zip") {
    let files: Record<string, Uint8Array>;
    try {
      files = unzipSync(bytes);
    } catch {
      return fail(null, { code: "file_invalid" });
    }
    const inner = Object.keys(files).find((f) => /(^|\/)expenses\.(csv|xlsx|json)$/i.test(f));
    if (!inner) return fail(null, { code: "zip_without_expenses" });
    format = formatOf(inner) as ImportFormat;
    bytes = files[inner]!;
  }
  if (format === null) return fail(null, { code: "format_unsupported" });

  let table: Table;
  try {
    table = await readTable(format, bytes);
  } catch (error) {
    if (error instanceof FileInvalid) return fail(format, { code: "file_invalid" });
    throw error;
  }

  const header = table.header.map((h) => h.trim());
  const known = ENTRY_COLUMNS.map((c) => c.name);
  const missing = REQUIRED_COLUMNS.filter((c) => !header.includes(c));
  if (missing.length > 0) return fail(format, { code: "columns_missing", columns: [...missing] });
  const unknown = header.filter((h) => h !== "" && !known.includes(h));
  if (unknown.length > 0) return fail(format, { code: "columns_unknown", columns: unknown });

  const rows = table.rows.filter((r) => r.cells.some((c) => c !== null && String(c).trim() !== ""));
  if (rows.length === 0) return fail(format, { code: "file_empty" });
  if (rows.length > MAX_ROWS) return fail(format, { code: "too_many_rows", limit: MAX_ROWS });

  return {
    format,
    errors: [],
    rows: rows.map((r) => {
      const cells: Record<string, FileCell> = {};
      header.forEach((h, i) => {
        if (h !== "") cells[h] = r.cells[i] ?? null;
      });
      return importRow(r.line, cells);
    }),
  };
}
