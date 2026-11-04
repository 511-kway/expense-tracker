import { assertEquals } from "jsr:@std/assert@1";
import { type Deps, handleClaudeIngest, MAX_BODY_BYTES } from "./handler.ts";

const TOKEN = "etk_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
/** SHA-256 этого токена (hex), посчитан отдельно: `printf %s "$TOKEN" | sha256sum`. */
const TOKEN_HASH = "39fa27e5905f8ce406c35c63d17ceecfddde465fdd885eda95e5e9acf76be970";
const ENTRY_ID = "11111111-1111-1111-1111-111111111111";

const expense = {
  type: "expense",
  occurred_on: "2026-11-02",
  amount_minor: 250000,
  account_id: "22222222-2222-2222-2222-222222222222",
  purpose: "work",
  category_id: "33333333-3333-3333-3333-333333333333",
};

/**
 * Подделка базы: RPC claude_ingest знает один хэш; запись с суммой ≤ 0 отклоняет, как движок.
 * Запоминает, что ей передали.
 */
function fakes(overrides: Partial<Deps> = {}) {
  const calls: { hash: string; request: Record<string, unknown> }[] = [];
  const deps: Deps = {
    ingest(hash, request) {
      calls.push({ hash, request });
      if (hash !== TOKEN_HASH) return Promise.resolve({ ok: false, error: "token_invalid" });
      const payload = request.payload as { amount_minor?: number } | undefined;
      if (request.action === "context") {
        return Promise.resolve({
          ok: true,
          accounts: [],
          categories: [],
          notes: [
            { id: "n1", text: "Такси", attachment_path: null },
            { id: "n2", text: null, attachment_path: "u/notes/shot.png" },
          ],
        });
      }
      if ((payload?.amount_minor ?? 0) <= 0) {
        return Promise.resolve({ ok: false, error: "amount_not_positive", details: {} });
      }
      return Promise.resolve({ ok: true, entry_id: ENTRY_ID, status: "done", warnings: [], source_pending: false });
    },
    signedUrl: (path) => Promise.resolve(`/storage/v1/object/sign/files/${path}?token=t`),
    ...overrides,
  };
  return { deps, calls };
}

function post(body: unknown, headers: Record<string, string> = { "X-Claude-Token": TOKEN }): Request {
  return new Request("http://localhost/claude_ingest", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function call(req: Request, deps: Deps) {
  const res = await handleClaudeIngest(req, deps);
  return { status: res.status, body: await res.json() };
}

Deno.test("good token creates the entry: entry_id, status and warnings come back", async () => {
  const { deps, calls } = fakes();
  assertEquals(await call(post({ action: "create_entry", payload: expense }), deps), {
    status: 200,
    body: { ok: true, entry_id: ENTRY_ID, status: "done", warnings: [], source_pending: false },
  });
  assertEquals(calls, [{ hash: TOKEN_HASH, request: { action: "create_entry", payload: expense } }]);
});

Deno.test("the token also works as Authorization: Bearer", async () => {
  const { deps } = fakes();
  const res = await call(
    post({ action: "create_entry", payload: expense }, { Authorization: `Bearer ${TOKEN}` }),
    deps,
  );
  assertEquals(res.status, 200);
});

Deno.test("an unknown token is rejected with 401", async () => {
  const { deps } = fakes();
  const other = "etk_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
  assertEquals(await call(post({ action: "create_entry", payload: expense }, { "X-Claude-Token": other }), deps), {
    status: 401,
    body: { ok: false, error: "token_invalid" },
  });
});

Deno.test("a missing or malformed token is rejected without asking the database", async () => {
  const { deps, calls } = fakes();
  const variants: Record<string, string>[] = [{}, { "X-Claude-Token": "secret" }, {
    Authorization: "Bearer eyJhbGciOi.jwt.sig",
  }];
  for (const headers of variants) {
    assertEquals(await call(post({ action: "create_entry", payload: expense }, headers), deps), {
      status: 401,
      body: { ok: false, error: "token_invalid" },
    });
  }
  assertEquals(calls.length, 0);
});

Deno.test("validation errors of create_entry are passed through with the same code", async () => {
  const { deps } = fakes();
  assertEquals(await call(post({ action: "create_entry", payload: { ...expense, amount_minor: 0 } }), deps), {
    status: 422,
    body: { ok: false, error: "amount_not_positive", details: {} },
  });
});

Deno.test("a user id in the body is never passed on: the owner comes from the token only", async () => {
  const { deps, calls } = fakes();
  await call(post({ action: "create_entry", payload: expense, user_id: "someone-else" }), deps);
  assertEquals(Object.keys(calls[0]!.request), ["action", "payload"]);
});

Deno.test("note → entry passes note_id along", async () => {
  const { deps, calls } = fakes();
  const res = await call(post({ action: "convert_note", note_id: "n1", payload: expense }), deps);
  assertEquals(res.status, 200);
  assertEquals(calls[0]!.request, { action: "convert_note", note_id: "n1", payload: expense });
});

Deno.test("context gives new notes with a short-lived link to the screenshot", async () => {
  const { deps } = fakes();
  const { status, body } = await call(post({ action: "context" }), deps);
  assertEquals(status, 200);
  assertEquals(body.notes, [
    { id: "n1", text: "Такси", attachment_path: null, attachment_url: null },
    {
      id: "n2",
      text: null,
      attachment_path: "u/notes/shot.png",
      attachment_url: "/storage/v1/object/sign/files/u/notes/shot.png?token=t",
    },
  ]);
});

Deno.test("status codes: rate_limited 429, not_allowed 403, field_invalid 400", async () => {
  for (const [error, status] of [["rate_limited", 429], ["not_allowed", 403], ["field_invalid", 400]] as const) {
    const { deps } = fakes({ ingest: () => Promise.resolve({ ok: false, error }) });
    assertEquals((await call(post({ action: "context" }), deps)).status, status);
  }
});

Deno.test("an unknown action or a body that is not a JSON object is field_invalid", async () => {
  const { deps, calls } = fakes();
  assertEquals(await call(post({ action: "delete_everything" }), deps), {
    status: 400,
    body: { ok: false, error: "field_invalid", details: { field: "action" } },
  });
  assertEquals(await call(post("not json"), deps), {
    status: 400,
    body: { ok: false, error: "field_invalid", details: { field: "body" } },
  });
  assertEquals(await call(post([1, 2]), deps), {
    status: 400,
    body: { ok: false, error: "field_invalid", details: { field: "body" } },
  });
  assertEquals(calls.length, 0);
});

Deno.test("a body over the size limit is refused before it is read", async () => {
  const { deps, calls } = fakes();
  const big = { action: "create_entry", payload: { ...expense, comment: "x".repeat(MAX_BODY_BYTES) } };
  assertEquals(await call(post(big), deps), { status: 413, body: { ok: false, error: "payload_too_large" } });
  assertEquals(calls.length, 0);
});

Deno.test("only POST", async () => {
  const { deps } = fakes();
  const res = await handleClaudeIngest(new Request("http://localhost/claude_ingest"), deps);
  assertEquals([res.status, await res.json()], [405, { ok: false, error: "method_not_allowed" }]);
});

Deno.test("the database failing is a 502, not a crash", async () => {
  const { deps } = fakes({ ingest: () => Promise.reject(new Error("connection refused")) });
  assertEquals(await call(post({ action: "context" }), deps), {
    status: 502,
    body: { ok: false, error: "server_unavailable" },
  });
});
