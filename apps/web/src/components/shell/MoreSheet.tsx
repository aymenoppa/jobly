/**
 * The phone's More sheet: Base UI's Drawer, so it follows a finger pulling it down and goes when let
 * go far or fast enough, and keeps focus, Escape and the page behind it like a dialog. Its own file,
 * loaded the first time the phone has a moment to spare (AppShell), so the drawer's code isn't part of
 * what every page has to download before it shows.
 */
import { Drawer } from "@base-ui/react/drawer";
import type { ReactNode } from "react";

export default function MoreSheet({ open, onOpenChange, label, children }: { open: boolean; onOpenChange: (open: boolean) => void; label: string; children: ReactNode }) {
  return (
    <Drawer.Root open={open} onOpenChange={(next) => onOpenChange(next)}>
      <Drawer.Portal>
        <Drawer.Backdrop className="sheet-backdrop" />
        <Drawer.Viewport className="sheet-viewport">
          <Drawer.Popup className="sheet" aria-label={label}>
            <Drawer.Content>{children}</Drawer.Content>
          </Drawer.Popup>
        </Drawer.Viewport>
      </Drawer.Portal>
    </Drawer.Root>
  );
}
