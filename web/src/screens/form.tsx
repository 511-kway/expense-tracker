import { useEffect, useRef, type ReactNode } from "react";
import { currencySign, formatAmountInput } from "../money";

/** Лист формы: снизу на телефоне, панелью справа на десктопе. Esc и «Закрыть» закрывают. */
export function SheetDialog({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      className="sheet"
      aria-labelledby="sheet-title"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      <div className="sheet__inner">
        <div className="sheet__head">
          <h2 id="sheet-title">{title}</h2>
          <button className="button button--quiet" type="button" onClick={onClose}>
            Закрыть
          </button>
        </div>
        {children}
      </div>
    </dialog>
  );
}

export function MoneyField(props: {
  id: string;
  label: string;
  side?: "own" | "company";
  value: string;
  onChange: (v: string) => void;
  currency?: string;
}) {
  return (
    <div className="field">
      <label htmlFor={props.id}>
        {props.side && <span className={`swatch swatch--${props.side}`} aria-hidden="true" />}
        {props.label}
      </label>
      <div className="money-input">
        <input
          id={props.id}
          type="text"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0"
          value={props.value}
          onChange={(e) => props.onChange(formatAmountInput(e.target.value))}
        />
        <span aria-hidden="true">{currencySign(props.currency ?? "KZT")}</span>
      </div>
    </div>
  );
}

