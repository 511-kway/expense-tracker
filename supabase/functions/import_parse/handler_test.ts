import { assertEquals } from "jsr:@std/assert@1";
import { ENTRY_COLUMNS } from "../_shared/schema.ts";
import { parseImportFile } from "./parse.ts";
import { type Deps, handleImportParse, MAX_FILE_BYTES } from "./handler.ts";

const deps: Deps = { isAllowed: (auth) => Promise.resolve(auth === "Bearer owner") };

function upload(name: string, content: string | Uint8Array, auth = "Bearer owner"): Request {
  const form = new FormData();
  form.append("file", new File([content as BlobPart], name));
  return new Request("http://localhost/import_parse", { method: "POST", headers: { Authorization: auth }, body: form });
}

Deno.test("an uploaded CSV becomes rows for the preview; nothing is written anywhere", async () => {
  const res = await handleImportParse(
    upload("expenses.csv", "occurred_on,type,account,amount\n2026-11-02,expense,Kaspi Gold,(1500.00)\n"),
    deps,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals([body.filename, body.format, body.errors], ["expenses.csv", "csv", []]);
  assertEquals(body.rows.map((r: { line: number; amount_minor: string }) => [r.line, r.amount_minor]), [[2, "150000"]]);
});

Deno.test("a file the schema cannot read is answered with the file errors, still 200", async () => {
  const res = await handleImportParse(upload("expenses.csv", "a,b\n1,2\n"), deps);
  assertEquals([res.status, (await res.json()).errors], [200, [{
    code: "columns_missing",
    columns: ["occurred_on", "type", "amount"],
  }]]);
});

Deno.test("only an allowed user may parse; a request without a file or with a huge one is refused", async () => {
  const stranger = await handleImportParse(upload("x.csv", "x", "Bearer stranger"), deps);
  assertEquals([stranger.status, await stranger.json()], [403, { error: "not_allowed" }]);

  const empty = await handleImportParse(
    new Request("http://localhost/import_parse", {
      method: "POST",
      headers: { Authorization: "Bearer owner" },
      body: new FormData(),
    }),
    deps,
  );
  assertEquals([empty.status, await empty.json()], [400, { error: "field_invalid", field: "file" }]);

  const huge = await handleImportParse(upload("x.csv", new Uint8Array(MAX_FILE_BYTES + 1)), deps);
  assertEquals([huge.status, await huge.json()], [413, { error: "file_too_large" }]);
});

Deno.test("the browser preflight gets CORS headers", async () => {
  const res = await handleImportParse(new Request("http://localhost/import_parse", { method: "OPTIONS" }), deps);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  await res.body?.cancel();
});

Deno.test("the template is the expenses file of the export schema with example rows, in every format", async () => {
  const get = (format: string, auth = "Bearer owner") =>
    handleImportParse(
      new Request(`http://localhost/import_parse?template=${format}`, { headers: { Authorization: auth } }),
      deps,
    );
  const csv = await get("csv");
  assertEquals(csv.status, 200);
  assertEquals(csv.headers.get("Content-Disposition"), 'attachment; filename="import_template.csv"');
  const bytes = new Uint8Array(await csv.arrayBuffer());
  const text = new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes);
  assertEquals(text.split("\r\n")[0], "﻿" + ENTRY_COLUMNS.map((c) => c.name).join(","));
  // Шаблон читается импортом без ошибок: он и есть пример правильного файла.
  const parsed = await parseImportFile("import_template.csv", bytes);
  assertEquals(parsed.errors, []);
  assertEquals(parsed.rows.every((r) => r.errors.length === 0), true);
  assertEquals(parsed.rows.length > 3, true);
  for (const format of ["json", "xlsx"]) {
    const res = await get(format);
    const back = await parseImportFile(`t.${format}`, new Uint8Array(await res.arrayBuffer()));
    assertEquals([res.status, back.errors, back.rows.length], [200, [], parsed.rows.length]);
  }
  const bad = await get("pdf");
  assertEquals([bad.status, await bad.json()], [400, { error: "field_invalid", field: "template" }]);
  const stranger = await get("csv", "Bearer stranger");
  assertEquals(stranger.status, 403);
  await stranger.body?.cancel();
});
