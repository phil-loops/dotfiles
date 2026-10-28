// A command's key as a faint label (a tab, a button) that lights for a moment when the key runs it,
// and glows while a half-typed prefix (g) waits for the key that would finish it.
import { glyph, keyOf } from "./registry";
import { fired } from "./runner";
import { pendingKeys } from "./ui";

export default function Key(props: { id: string; class?: string }) {
  return (
    <span class={`rv-hintkey ${props.class ?? ""}`} classList={{ "rv-fired": !!fired()?.ok && fired()!.id === props.id, "rv-armed": !!pendingKeys() && keyOf(props.id).startsWith(`${glyph(pendingKeys())} `) }}>
      {keyOf(props.id)}
    </span>
  );
}
