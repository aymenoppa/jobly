import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { loadConfig } from "./lib/api";
import { startSlidingIndicators } from "./lib/indicator";
import { lockZoomInApp, watchInstall } from "./lib/install";
import { startLocale, tellIfSpanishDidntLoad } from "./lib/i18n";
import { registerServiceWorker } from "./lib/push";
import { initTheme } from "./lib/theme";
import "@fontsource-variable/figtree";
import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/components.css";
import "./styles/features.css";

// Start fetching settings right away: it also turns on error reporting, client pages included.
loadConfig().catch(() => undefined);
initTheme();
registerServiceWorker();
watchInstall();
lockZoomInApp();
startSlidingIndicators();

// Spanish, for whoever chose it, loads before the first screen (English has nothing to load). It
// gets a few seconds: after that the app opens in English and says so, with a way to try again.
void startLocale().then(() => {
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
  tellIfSpanishDidntLoad();
});
