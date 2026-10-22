// Local UI state the commands move: the cursor, the menu, the key sheet, the archive fold.
import { createSignal } from "solid-js";

export const [cursor, setCursor] = createSignal<string | undefined>();
export const [cursorIdx, setCursorIdx] = createSignal(0);
export const [menuOpen, setMenuOpen] = createSignal(false);
export const [sheetOpen, setSheetOpen] = createSignal(false);
export const [showArchive, setShowArchive] = createSignal(false);
export const [pendingKeys, setPendingKeys] = createSignal("");
export const [dashDays, setDashDays] = createSignal(30);
