import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { nbkDate, parseNbkRates } from "./nbk.ts";

// Отрывок настоящего ответа https://nationalbank.kz/rss/get_rates.cfm?fdate=03.11.2026:
// курс за quant единиц валюты в поле description.
const XML = `<?xml version="1.0" encoding="utf-8"?>
<rates>
    <generator>Alternate RSS Builder</generator>
    <title>Official exchange rates of National Bank of Republic Kazakhstan</title>
    <date>03.11.2026</date>
            <item>
            <fullname>АРМЯНСКИЙ ДРАМ</fullname>
            <title>AMD</title>
            <description>12.63</description>
            <quant>10</quant>
            <index>DOWN</index>
            <change>-0.03</change>
            </item>
            <item>
            <fullname>ДОЛЛАР США</fullname>
            <title>USD</title>
            <description>453.64</description>
            <quant>1</quant>
            <index>DOWN</index>
            <change>-1.64</change>
            </item>
            <item>
            <fullname>ВОН РЕСПУБЛИКИ КОРЕЯ</fullname>
            <title>KRW</title>
            <description>33.81</description>
            <quant>100</quant>
            <index>DOWN</index>
            <change>-0.11</change>
            </item>
            <item>
            <fullname>ВЬЕТНАМСКИЙ ДОНГ</fullname>
            <title>VND</title>
            <description>17.62</description>
            <quant>3000</quant>
            </item>
</rates>`;

Deno.test("a date for the National Bank is DD.MM.YYYY", () => {
  assertEquals(nbkDate("2026-11-03"), "03.11.2026");
});

Deno.test("rates are tenge per one unit: the quoted rate over quant, as a decimal string", () => {
  assertEquals(parseNbkRates(XML), [
    { currency: "AMD", rate: "1.263" },
    { currency: "USD", rate: "453.64" },
    { currency: "KRW", rate: "0.3381" },
    // 17,62 / 3000 = 0,00587333… → 8 знаков с округлением.
    { currency: "VND", rate: "0.00587333" },
  ]);
});

Deno.test("a date without rates gives an empty list", () => {
  const xml = `<?xml version="1.0" encoding="utf-8"?>
<rates>
    <date>08.11.2026</date>
            <info>на выбранную дату информации нет.</info>
    </rates>`;
  assertEquals(parseNbkRates(xml), []);
});

Deno.test("an answer that is not the rates feed is an error", () => {
  assertThrows(() => parseNbkRates(`{"code":500,"message":"Invalid format date."}`));
  assertThrows(() =>
    parseNbkRates(`<rates><item><title>USD</title><description>4,5</description><quant>1</quant></item></rates>`)
  );
});
