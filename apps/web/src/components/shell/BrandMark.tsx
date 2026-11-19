/** The angular Jobly J (same shapes as public/jobly-mark.svg). */
export function BrandMark({ size = 28, className }: { size?: number; className?: string }) {
  return (
    <svg className={className} width={(size * 211) / 251} height={size} viewBox="0 0 211 251" aria-hidden="true" focusable="false">
      <path fill="var(--brand-ink, #182430)" d="M145 44H189V203L105 251 21 203V153L105 201 145 178Z" />
      <path fill="#F4B143" d="M42 0H211V44H0Z" />
    </svg>
  );
}

/** Mark and name together, for the sidebar and sign-in pages. */
export function BrandLockup({ size = 28 }: { size?: number }) {
  return (
    <>
      <BrandMark size={size} />
      <span className="brand-name">Jobly</span>
    </>
  );
}
