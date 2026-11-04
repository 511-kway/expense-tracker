// Официальные курсы Национального банка РК: https://nationalbank.kz/rss/get_rates.cfm?fdate=DD.MM.YYYY.
// Ответ XML: <rates><date>…</date><item><title>USD</title><description>453.64</description>
// <quant>1</quant>…</item>…</rates>; курс в description за quant единиц валюты. На дату без
// курсов вместо item приходит <info>. Курс здесь только строкой десятичной дроби, без float.

export type NbkRate = { currency: string; rate: string };

/** Дата ISO (ГГГГ-ММ-ДД) → формат параметра fdate. */
export function nbkDate(isoDate: string): string {
  const [year, month, day] = isoDate.split("-");
  return `${day}.${month}.${year}`;
}

const SCALE = 8; // numeric(18,8) в fx_rates

/** "17.62" / 3000 → "0.00587333": деление десятичной строки на целое, 8 знаков, половина вверх. */
function divide(decimal: string, quant: bigint): string {
  const match = /^(\d+)(?:\.(\d+))?$/.exec(decimal);
  if (!match || quant <= 0n) throw new Error(`bad rate: ${decimal} / ${quant}`);
  const fraction = match[2] ?? "";
  const numerator = BigInt((match[1] ?? "") + fraction) * 10n ** BigInt(SCALE);
  const denominator = 10n ** BigInt(fraction.length) * quant;
  const scaled = (numerator * 2n + denominator) / (denominator * 2n);
  const digits = scaled.toString().padStart(SCALE + 1, "0");
  const whole = digits.slice(0, -SCALE);
  const rest = digits.slice(-SCALE).replace(/0+$/, "");
  return rest === "" ? whole : `${whole}.${rest}`;
}

function tag(xml: string, name: string): string | null {
  const match = new RegExp(`<${name}>\\s*([^<]*?)\\s*</${name}>`).exec(xml);
  return match ? (match[1] ?? "") : null;
}

/** XML ответа → курсы за одну единицу валюты. Не лента курсов или битый курс → ошибка. */
export function parseNbkRates(xml: string): NbkRate[] {
  if (!/<rates>/.test(xml)) throw new Error("not the National Bank rates feed");
  const items = xml.match(/<item>[\s\S]*?<\/item>/g) ?? [];
  return items.map((item) => {
    const currency = tag(item, "title");
    const rate = tag(item, "description");
    const quant = tag(item, "quant");
    if (!currency || !/^[A-Z]{3}$/.test(currency) || rate === null || quant === null || !/^\d+$/.test(quant)) {
      throw new Error(`bad item: ${item}`);
    }
    return { currency, rate: divide(rate, BigInt(quant)) };
  });
}
