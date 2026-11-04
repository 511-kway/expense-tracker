import { formatRate, minorToAmountInput, parseAmountInput, parseRateInput } from "./money";

/** Валюты в выборе счёта и суммы. Тенге первым: валюта по умолчанию. */
export const CURRENCIES = ["KZT", "USD", "EUR", "RUB", "TRY", "CNY"];

export const CURRENCY_NAMES: Record<string, string> = {
  KZT: "Тенге",
  USD: "Доллар США",
  EUR: "Евро",
  RUB: "Рубль",
  TRY: "Лира",
  CNY: "Юань",
};

/** Способ получить тенговый эквивалент (rate_source, док 03, раздел 5). */
export type RateMethod = "nbk" | "manual" | "derived";

export const RATE_METHODS: Record<RateMethod, string> = {
  nbk: "Курс Нацбанка",
  manual: "Свой курс",
  derived: "Сумма в тенге",
};

/** Ввод блока пересчёта: способ, свой курс и сумма в тенге текстом полей. */
export type ConversionInput = { method: RateMethod; rate: string; kzt: string };

export type ConversionFields = { rate_source?: RateMethod; rate?: string; amount_kzt_minor?: number };

/**
 * Блок пересчёта → поля payload (rate_source, rate, amount_kzt_minor) или что ещё не заполнено.
 * Эквивалент не считается здесь: его считает и округляет сервер.
 */
export function conversionFields(currency: string, input: ConversionInput): ConversionFields | string {
  if (currency === "KZT") return {};
  if (input.method === "nbk") return { rate_source: "nbk" };
  if (input.method === "manual") {
    const parsed = parseRateInput(input.rate);
    if (!parsed.ok) return parsed.error === "empty" ? "Введите курс." : "Введите курс цифрами, не больше 8 знаков после запятой.";
    return { rate_source: "manual", rate: parsed.rate };
  }
  const kzt = parseAmountInput(input.kzt);
  if (!kzt.ok)
    return kzt.error === "empty" ? "Введите сумму в тенге." : "Введите сумму в тенге цифрами, тиыны не больше двух знаков.";
  if (kzt.minor === 0) return "Сумма в тенге должна быть больше нуля.";
  return { rate_source: "derived", amount_kzt_minor: kzt.minor };
}

/** Блок пересчёта при правке записи: как она была пересчитана. Новая запись: курс Нацбанка. */
export function conversionFromEntry(
  entry: { rate_source: RateMethod | null; rate: number | string | null; amount_kzt_minor: number | null } | undefined,
): ConversionInput {
  if (entry?.rate_source === "manual" && entry.rate !== null) return { method: "manual", rate: formatRate(entry.rate), kzt: "" };
  if (entry?.rate_source === "derived" && entry.amount_kzt_minor !== null)
    return { method: "derived", rate: "", kzt: minorToAmountInput(entry.amount_kzt_minor) };
  return { method: "nbk", rate: "", kzt: "" };
}
