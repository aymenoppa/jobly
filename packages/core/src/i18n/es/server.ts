/**
 * What the server writes to a team member in their language (apps/api, with translator(locale)):
 * the emails, texts and pushes that carry their notifications. The notifications themselves are in
 * notices.ts. GLOSSARY.md first.
 */
import type { Catalog } from "../index";

export default {
  // services/delivery.ts
  "{count} updates from {company}:": "{count} novedades de {company}:",
  "{count} updates from {company}": "{count} novedades de {company}",
  "You get these because of your notification settings. Change them in Jobly under Settings → Profile: {link}": "Te llegan por tu configuración de notificaciones. Cámbiala en Jobly en Configuración → Perfil: {link}",
  "You get these because of your notification settings. Change them in Jobly under Settings → Profile.": "Te llegan por tu configuración de notificaciones. Cámbiala en Jobly en Configuración → Perfil.",
  " (+{count} more)": " (+{count} más)",
} satisfies Catalog;
