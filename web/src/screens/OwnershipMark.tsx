/** Знак приложения: полоса принадлежности (свои и аванс), см. docs/design.md. */
export function OwnershipMark({ className }: { className?: string }) {
  return (
    <div className={`ownership-bar ${className ?? ""}`} aria-hidden="true">
      <span className="own" style={{ flexGrow: 3 }} />
      <span className="company" style={{ flexGrow: 2 }} />
    </div>
  );
}
