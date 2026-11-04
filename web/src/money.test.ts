import { describe, expect, it } from "vitest";
import { amountOrZero, formatAmountInput, formatMoney, minorToAmountInput, parseAmountInput } from "./money";

const NB = " ";

describe("formatMoney", () => {
  it("shows whole tenge with nbsp thousands and no kopecks", () => {
    expect(formatMoney(150_000_000, "KZT")).toBe(`1${NB}500${NB}000${NB}₸`);
  });

  it("shows kopecks after a comma when they are not zero", () => {
    expect(formatMoney(150_050, "KZT")).toBe(`1${NB}500,50${NB}₸`);
    expect(formatMoney(5, "KZT")).toBe(`0,05${NB}₸`);
  });

  it("puts a minus sign in front of negative amounts", () => {
    expect(formatMoney(-150_050, "KZT")).toBe(`−1${NB}500,50${NB}₸`);
    expect(formatMoney(-5, "KZT")).toBe(`−0,05${NB}₸`);
  });

  it("puts the dollar sign in front and other currency signs after", () => {
    expect(formatMoney(120_000, "USD")).toBe(`$1${NB}200`);
    expect(formatMoney(-120_050, "USD")).toBe(`−$1${NB}200,50`);
    expect(formatMoney(99_900, "EUR")).toBe(`999${NB}€`);
    expect(formatMoney(100, "TRY")).toBe(`1${NB}₺`);
    expect(formatMoney(100, "CNY")).toBe(`1${NB}CNY`);
  });

  it("refuses amounts that are not whole minor units", () => {
    expect(() => formatMoney(10.5, "KZT")).toThrow();
  });
});

describe("parseAmountInput", () => {
  it("reads whole tenge typed with thousands separators", () => {
    expect(parseAmountInput("1 500 000")).toEqual({ ok: true, minor: 150_000_000 });
    expect(parseAmountInput(`1${NB}500`)).toEqual({ ok: true, minor: 150_000 });
    expect(parseAmountInput("8400")).toEqual({ ok: true, minor: 840_000 });
  });

  it("reads kopecks after a comma or a dot", () => {
    expect(parseAmountInput("1 500,5")).toEqual({ ok: true, minor: 150_050 });
    expect(parseAmountInput("1500.50")).toEqual({ ok: true, minor: 150_050 });
    expect(parseAmountInput("0,05")).toEqual({ ok: true, minor: 5 });
    expect(parseAmountInput("12,")).toEqual({ ok: true, minor: 1_200 });
  });

  it("rejects more than two digits after the separator", () => {
    expect(parseAmountInput("1,505")).toEqual({ ok: false, error: "too_many_decimals" });
  });

  it("rejects empty text, letters, signs and two separators", () => {
    expect(parseAmountInput("  ")).toEqual({ ok: false, error: "empty" });
    expect(parseAmountInput("12a")).toEqual({ ok: false, error: "invalid" });
    expect(parseAmountInput("-100")).toEqual({ ok: false, error: "invalid" });
    expect(parseAmountInput("1,5.0")).toEqual({ ok: false, error: "invalid" });
    expect(parseAmountInput(",5")).toEqual({ ok: false, error: "invalid" });
  });

  it("is exact for amounts where float arithmetic drifts", () => {
    expect(parseAmountInput("0,29")).toEqual({ ok: true, minor: 29 });
    expect(parseAmountInput("1 234 567,89")).toEqual({ ok: true, minor: 123_456_789 });
  });
});

describe("formatAmountInput", () => {
  it("groups thousands while typing and keeps what the user typed after the separator", () => {
    expect(formatAmountInput("1500000")).toBe(`1${NB}500${NB}000`);
    expect(formatAmountInput("1 500000,5")).toBe(`1${NB}500${NB}000,5`);
    expect(formatAmountInput("1500.")).toBe(`1${NB}500.`);
    expect(formatAmountInput("")).toBe("");
  });

  it("leaves text it cannot read unchanged so the user can fix it", () => {
    expect(formatAmountInput("12a4")).toBe("12a4");
  });
});

describe("amountOrZero", () => {
  it("treats an empty optional amount field as zero", () => {
    expect(amountOrZero("")).toBe(0);
    expect(amountOrZero("  ")).toBe(0);
  });
  it("reads a typed amount in minor units", () => {
    expect(amountOrZero("1 500,50")).toBe(150050);
  });
  it("gives null for input that is not an amount", () => {
    expect(amountOrZero("12,345")).toBeNull();
    expect(amountOrZero("abc")).toBeNull();
  });
});

describe("minorToAmountInput", () => {
  it("turns a saved amount back into the input text, round trip with parseAmountInput", () => {
    expect(minorToAmountInput(6000000)).toBe("60\u00a0000");
    expect(minorToAmountInput(150050)).toBe("1\u00a0500,50");
    expect(minorToAmountInput(5)).toBe("0,05");
    expect(parseAmountInput(minorToAmountInput(150050))).toEqual({ ok: true, minor: 150050 });
  });
});
