/** The kinhin ring (assets/brand/mark.svg): a stroked circle in the current colour. */
export function Logo({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <circle cx="32" cy="32" r="18.25" fill="none" stroke="currentColor" strokeWidth="3.5" />
    </svg>
  )
}
