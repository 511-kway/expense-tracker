// Строки файла → байты CSV, JSON или xlsx; два файла экспорта → один zip (док 04, раздел 9).
// Даты ISO, суммы с двумя знаками через точку без разделителей. CSV и JSON: минус обычным
// числом `-1500.00`. xlsx: сумма остаётся числом, формат ячейки бухгалтерский с минусом красным.
// xlsx пишет write-excel-file (MIT, на fflate), zip собирает fflate (MIT): оба чистый JS без Node API.
import writeXlsxFile from "npm:write-excel-file@4.1.1/universal";
import { strToU8, zipSync } from "npm:fflate@0.8.2";
import type { Column, FileRecord, Money, Value } from "../_shared/schema.ts";

export type ExportFormat = "csv" | "xlsx" | "json";

export const EXPORT_FORMATS: readonly ExportFormat[] = ["csv", "xlsx", "json"];

/** Формат денежной ячейки xlsx: разделитель тысяч, отрицательные в скобках красным. */
export const XLSX_MONEY_FORMAT = "#,##0.00;[Red](#,##0.00)";

function isMoney(value: Value): value is Money {
  return typeof value === "object" && value !== null && "money" in value;
}

function plain(value: Value): string {
  if (value === null) return "";
  if (isMoney(value)) return value.money;
  return String(value);
}

function csvField(text: string): string {
  return /[",\r\n]|^\s|\s$/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

/**
 * CSV по RFC 4180: запятая, строки через CRLF, кавычки только где нужны. В начале BOM UTF-8,
 * чтобы Excel открыл кириллицу; импорт его пропускает.
 */
export function toCsv(columns: readonly Column[], records: readonly FileRecord[]): string {
  const lines = [columns.map((c) => csvField(c.name)).join(",")];
  for (const record of records) lines.push(columns.map((c) => csvField(plain(record[c.name] ?? null))).join(","));
  return "﻿" + lines.join("\r\n") + "\r\n";
}

/**
 * JSON: массив объектов с ключами в порядке схемы, пусто = null. Сумма пишется числом прямо из
 * десятичной строки (`-1500.00`), без JSON.stringify числа, чтобы не терять знаки и не идти через float.
 */
export function toJson(columns: readonly Column[], records: readonly FileRecord[]): string {
  if (records.length === 0) return "[]\n";
  const rows = records.map((record) => {
    const fields = columns.map((c) => {
      const value = record[c.name] ?? null;
      const literal = isMoney(value) ? value.money : JSON.stringify(value);
      return `${JSON.stringify(c.name)}: ${literal}`;
    });
    return `  {${fields.join(", ")}}`;
  });
  return `[\n${rows.join(",\n")}\n]\n`;
}

type XlsxCell = {
  value: string | number | boolean;
  type?: StringConstructor | NumberConstructor | BooleanConstructor;
  format?: string;
} | null;

function xlsxCell(kind: Column["kind"], value: Value): XlsxCell {
  if (value === null) return null;
  if (isMoney(value)) return { value: Number(value.money), type: Number, format: XLSX_MONEY_FORMAT };
  if (typeof value === "boolean") return { value, type: Boolean };
  if (kind === "rate") return { value: Number(value), type: Number };
  // Дата остаётся текстом ГГГГ-ММ-ДД: так её читает импорт и так её видит Claude.
  return { value, type: String };
}

/** xlsx с одним листом: шапка текстом, деньги числовыми ячейками в формате XLSX_MONEY_FORMAT. */
export async function toXlsx(sheet: string, columns: readonly Column[], records: readonly FileRecord[]) {
  const header = columns.map((c) => ({ value: c.name, type: String, fontWeight: "bold" as const }));
  const rows = records.map((record) => columns.map((c) => xlsxCell(c.kind, record[c.name] ?? null)));
  const blob = await writeXlsxFile([header, ...rows] as never, { sheet }).toBlob();
  return new Uint8Array(await blob.arrayBuffer());
}

export async function renderFile(
  format: ExportFormat,
  name: string,
  columns: readonly Column[],
  records: readonly FileRecord[],
): Promise<Uint8Array> {
  switch (format) {
    case "csv":
      return strToU8(toCsv(columns, records));
    case "json":
      return strToU8(toJson(columns, records));
    case "xlsx":
      return await toXlsx(name, columns, records);
  }
}

export type ExportFile = { name: string; columns: readonly Column[]; records: readonly FileRecord[] };

/** Файлы одного формата → zip (`expenses.csv`, `company_settlement.csv`). */
export async function zipFiles(format: ExportFormat, files: readonly ExportFile[]): Promise<Uint8Array> {
  const entries: Record<string, Uint8Array> = {};
  for (const file of files) {
    entries[`${file.name}.${format}`] = await renderFile(format, file.name, file.columns, file.records);
  }
  return zipSync(entries);
}
