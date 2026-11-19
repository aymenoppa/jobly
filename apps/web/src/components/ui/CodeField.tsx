/**
 * A code sent by text or email, typed one digit to a box (Base UI's OTP field). The phone offers the
 * code above its keyboard and fills every box at once; a pasted "123 456" does too; Backspace steps
 * back a box. The first box is named by the field's label (a Field gives it one; elsewhere, a <label>
 * for `id`); the others say which digit they are.
 */
import { OTPField } from "@base-ui/react/otp-field";
import { t } from "@/lib/i18n";

export function CodeField({
  length,
  value,
  onChange,
  normalize,
  id,
  autoFocus,
  disabled,
}: {
  length: number;
  value: string;
  onChange: (value: string) => void;
  /**
   * Picks the code out of whatever arrived (a whole pasted message, say). Without it, anything but
   * digits is dropped.
   */
  normalize?: (value: string) => string;
  /** The first box's id, for a <label htmlFor> outside a Field. */
  id?: string;
  autoFocus?: boolean;
  disabled?: boolean;
}) {
  return (
    <OTPField.Root
      id={id}
      className="code-field"
      length={length}
      value={value}
      onValueChange={(next) => onChange(next)}
      inputMode="numeric"
      validationType={normalize ? "none" : "numeric"}
      normalizeValue={normalize}
      disabled={disabled}
    >
      {Array.from({ length }, (_, i) => (
        <OTPField.Input
          key={i}
          className="code-slot"
          autoFocus={autoFocus && i === 0}
          aria-label={i === 0 ? undefined : t("Digit {n} of {length}", { n: i + 1, length })}
        />
      ))}
    </OTPField.Root>
  );
}
