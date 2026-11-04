import { assert, assertEquals } from "jsr:@std/assert@1";
import { strFromU8, unzipSync } from "npm:fflate@0.8.2";
import type { Column, FileRecord } from "../_shared/schema.ts";
import { toCsv, toJson, toXlsx, XLSX_MONEY_FORMAT } from "./format.ts";

const columns: Column[] = [
  { name: "occurred_on", kind: "date" },
  { name: "type", kind: "text" },
  { name: "amount", kind: "money" },
  { name: "comment", kind: "text" },
  { name: "rate", kind: "rate" },
  { name: "in_analytics", kind: "bool" },
];

const records: FileRecord[] = [
  {
    occurred_on: "2026-11-02",
    type: "expense",
    amount: { money: "-1500.00" },
    comment: "Обед, с «Алиной»",
    rate: null,
    in_analytics: true,
  },
  {
    occurred_on: "2026-11-03",
    type: "income",
    amount: { money: "1500000.00" },
    comment: 'сказал "ок"\nвторая строка',
    rate: "453.64",
    in_analytics: false,
  },
];

Deno.test("CSV: header, ISO dates, -1500.00 and 1500000.00 without separators, quoted text", () => {
  assertEquals(
    toCsv(columns, records),
    "﻿" +
      "occurred_on,type,amount,comment,rate,in_analytics\r\n" +
      '2026-11-02,expense,-1500.00,"Обед, с «Алиной»",,true\r\n' +
      '2026-11-03,income,1500000.00,"сказал ""ок""\nвторая строка",453.64,false\r\n',
  );
});

Deno.test("JSON: amounts are plain numbers with two digits, empty is null", () => {
  const text = toJson(columns, records);
  assert(text.includes(`"amount": -1500.00,`));
  assert(text.includes(`"amount": 1500000.00,`));
  assertEquals(JSON.parse(text), [
    {
      occurred_on: "2026-11-02",
      type: "expense",
      amount: -1500,
      comment: "Обед, с «Алиной»",
      rate: null,
      in_analytics: true,
    },
    {
      occurred_on: "2026-11-03",
      type: "income",
      amount: 1500000,
      comment: 'сказал "ок"\nвторая строка',
      rate: "453.64",
      in_analytics: false,
    },
  ]);
  assertEquals(toJson(columns, []), "[]\n");
});

async function xlsxParts() {
  const files = unzipSync(await toXlsx("expenses", columns, records));
  return {
    sheet: strFromU8(files["xl/worksheets/sheet1.xml"]!),
    styles: strFromU8(files["xl/styles.xml"]!),
    strings: strFromU8(files["xl/sharedStrings.xml"]!),
    workbook: strFromU8(files["xl/workbook.xml"]!),
  };
}

function cell(sheet: string, ref: string): string {
  const match = new RegExp(`<c r="${ref}"[^>]*?(/>|>.*?</c>)`).exec(sheet);
  if (!match) throw new Error(`no cell ${ref}`);
  return match[0];
}

Deno.test("xlsx: amounts are numeric cells formatted #,##0.00;[Red](#,##0.00)", async () => {
  const { sheet, styles } = await xlsxParts();
  const negative = cell(sheet, "C2");
  const positive = cell(sheet, "C3");
  // Числовая ячейка: без t="s"/t="str", значение число со знаком.
  assert(!/ t="/.test(negative), negative);
  assert(negative.includes("<v>-1500</v>"), negative);
  assert(positive.includes("<v>1500000</v>"), positive);

  const style = Number(/ s="(\d+)"/.exec(negative)![1]);
  assertEquals(/ s="(\d+)"/.exec(positive)![1], String(style));
  const cellXfs = /<cellXfs[^>]*>(.*?)<\/cellXfs>/.exec(styles)![1]!;
  const xf = [...cellXfs.matchAll(/<xf\b[^>]*>/g)][style]![0];
  const numFmtId = /numFmtId="(\d+)"/.exec(xf)![1];
  assert(
    styles.includes(`<numFmt numFmtId="${numFmtId}" formatCode="${XLSX_MONEY_FORMAT}"/>`),
    `style ${style} → numFmt ${numFmtId}: ${styles}`,
  );
});

Deno.test("xlsx: the date stays ISO text, the sheet is named after the file", async () => {
  const { sheet, strings, workbook } = await xlsxParts();
  assert(cell(sheet, "A2").includes('t="s"'));
  assert(strings.includes("<t>2026-11-02</t>"));
  assert(strings.includes("<t>occurred_on</t>"));
  assert(workbook.includes('name="expenses"'));
  // Пустая ячейка курса не пишется числом ноль.
  assert(!/<c r="E2"[^>]*><v>/.test(sheet));
  assert(cell(sheet, "E3").includes("<v>453.64</v>"));
  assert(cell(sheet, "F2").includes('t="b"'));
});
