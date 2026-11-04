export function AvailabilityPill({ children = "Not connected" }: { children?: string }) {
  return <span className="status-pill"><i aria-hidden="true" />{children}</span>;
}
