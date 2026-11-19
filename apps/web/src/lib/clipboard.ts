import { toast } from "./toast";
import { t } from "@/lib/i18n";

/** Copy text and confirm with a toast; falls back to a prompt where the clipboard is blocked. */
export async function copyText(text: string, label = t("Copied to clipboard")) {
  try {
    await navigator.clipboard.writeText(text);
    toast.success(label);
  } catch {
    window.prompt(t("Copy this:"), text);
  }
}
