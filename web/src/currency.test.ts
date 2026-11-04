import { describe, expect, it } from "vitest";
import { conversionFields, conversionFromEntry } from "./currency";

describe("conversionFields", () => {
  it("tenge needs no conversion", () => {
    expect(conversionFields("KZT", { method: "manual", rate: "2", kzt: "" })).toEqual({});
  });

  it("the National Bank rate: only the method, the server takes the rate on the date", () => {
    expect(conversionFields("USD", { method: "nbk", rate: "1", kzt: "5" })).toEqual({ rate_source: "nbk" });
  });

  it("an own rate goes as a decimal string", () => {
    expect(conversionFields("USD", { method: "manual", rate: "453,87", kzt: "" })).toEqual({
      rate_source: "manual",
      rate: "453.87",
    });
    expect(conversionFields("USD", { method: "manual", rate: "", kzt: "" })).toBe("Введите курс.");
    expect(conversionFields("USD", { method: "manual", rate: "4,5,6", kzt: "" })).toBe(
      "Введите курс цифрами, не больше 8 знаков после запятой.",
    );
  });

  it("a tenge amount goes in tiyn", () => {
    expect(conversionFields("USD", { method: "derived", rate: "", kzt: "48 000" })).toEqual({
      rate_source: "derived",
      amount_kzt_minor: 4_800_000,
    });
    expect(conversionFields("USD", { method: "derived", rate: "", kzt: "" })).toBe("Введите сумму в тенге.");
  });
});

describe("conversionFromEntry", () => {
  it("opens the way the entry was converted", () => {
    expect(conversionFromEntry({ rate_source: "manual", rate: 480.015, amount_kzt_minor: 48_002 })).toEqual({
      method: "manual",
      rate: "480,015",
      kzt: "",
    });
    expect(conversionFromEntry({ rate_source: "derived", rate: 480, amount_kzt_minor: 4_800_000 })).toEqual({
      method: "derived",
      rate: "",
      kzt: "48\u00a0000",
    });
    expect(conversionFromEntry(undefined)).toEqual({ method: "nbk", rate: "", kzt: "" });
  });
});
