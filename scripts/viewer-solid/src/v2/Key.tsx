// A command's key as a faint label (a tab, a button) that lights for a moment when the key runs it.
import { keyOf } from "./registry";
import { fired } from "./runner";

export default function Key(props: { id: string; class?: string }) {
  return (
    <span class={`rv-hintkey ${props.class ?? ""}`} classList={{ "rv-fired": !!fired()?.ok && fired()!.id === props.id }}>
      {keyOf(props.id)}
    </span>
  );
}
