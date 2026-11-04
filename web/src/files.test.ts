import { describe, expect, it } from "vitest";
import { attachmentKind, fileProblem, notePrefill, storagePath } from "./files";

describe("fileProblem", () => {
  it("accepts screenshots, photos and PDF up to 20 MB", () => {
    expect(fileProblem({ type: "image/png", size: 1_000_000 })).toBeNull();
    expect(fileProblem({ type: "image/heic", size: 3_000_000 })).toBeNull();
    expect(fileProblem({ type: "application/pdf", size: 20 * 1024 * 1024 })).toBeNull();
  });

  it("explains what is wrong with another type or a bigger file", () => {
    expect(fileProblem({ type: "text/html", size: 10 })).toBe("Можно приложить картинку (JPG, PNG, HEIC, WebP, GIF) или PDF.");
    expect(fileProblem({ type: "image/jpeg", size: 20 * 1024 * 1024 + 1 })).toBe("Файл больше 20 МБ: сожмите его или сделайте скрин.");
  });
});

describe("storagePath", () => {
  it("puts the file into the owner's folder with its extension", () => {
    expect(storagePath("u1", "notes", { name: "IMG_0042.JPG", type: "image/jpeg" }, "f1")).toBe("u1/notes/f1.jpg");
    expect(storagePath("u1", "entries/e1", { name: "invoice.pdf", type: "application/pdf" }, "f2")).toBe(
      "u1/entries/e1/f2.pdf",
    );
  });

  it("takes the extension from the type when the name has none", () => {
    expect(storagePath("u1", "notes", { name: "image", type: "image/png" }, "f3")).toBe("u1/notes/f3.png");
  });
});

describe("attachmentKind", () => {
  it("calls a PDF an invoice and a picture a receipt", () => {
    expect(attachmentKind("application/pdf")).toBe("invoice");
    expect(attachmentKind("image/jpeg")).toBe("receipt");
  });
});

describe("notePrefill", () => {
  it("takes the first line as the title and keeps the whole note as the comment", () => {
    expect(notePrefill("Такси до офиса\nKaspi, работа")).toEqual({
      title: "Такси до офиса",
      comment: "Такси до офиса\nKaspi, работа",
    });
  });

  it("shortens a long first line and leaves an empty note empty", () => {
    expect(notePrefill("а".repeat(100)).title).toBe("а".repeat(79) + "…");
    expect(notePrefill(null)).toEqual({ title: "", comment: "" });
  });
});
