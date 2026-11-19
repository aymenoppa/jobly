/**
 * "Using ChatGPT plan", with Manage usage, beside an AI button: shown to someone whose own ChatGPT
 * plan answers what they ask (Apps → ChatGPT), as OpenAI asks apps to say wherever a plan is in use.
 * Nothing shows for anyone else.
 */
import { Icon } from "@/components/ui/Icon";
import { t } from "@/lib/i18n";
import { useSession } from "@/lib/session";

export function UsingChatGptPlan() {
  const session = useSession();
  if (!session.config.features.chatgptPlan) return null;
  return (
    <span className="muted small">
      {t("Using ChatGPT plan")} · <a href="https://chatgpt.com/settings/usage" target="_blank" rel="noreferrer">{t("Manage usage")} <Icon name="external" size={12} /></a>
    </span>
  );
}
