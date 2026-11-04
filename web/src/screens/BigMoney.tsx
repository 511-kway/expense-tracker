import { formatMoney } from "../money";

/** Крупная сумма в тенге: знак валюты на ступень меньше и тоньше (docs/design.md). */
export function BigMoney({ minor }: { minor: number }) {
  const text = formatMoney(minor, "KZT");
  const sign = "\u00a0₸";
  if (!text.endsWith(sign)) return <>{text}</>;
  return (
    <>
      {text.slice(0, -sign.length)}
      <span className="currency">{sign}</span>
    </>
  );
}
