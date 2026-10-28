// The jumplist and the picker: C-o goes back to where a jump left from, C-i forward again; the
// picker's own keys live in its filter box (Picker.tsx), so they're registered without keys here.
import { nav } from "../nav";
import { command } from "../registry";

command({ id: "nav.back", label: "back", title: "Jump back to where you were (the jumplist)", scope: "global", budget: "local", keys: ["C-o"], available: () => nav.back().length > 0, local: () => void nav.goBack() });
command({ id: "nav.forward", label: "forward", title: "Jump forward again (the jumplist)", scope: "global", budget: "local", keys: ["C-i"], available: () => nav.fwd().length > 0, local: () => void nav.goForward() });

command({ id: "picker.down", title: "Next place in the picker", scope: "global", budget: "local", quiet: true, available: () => !!nav.picker(), local: () => nav.move(1) });
command({ id: "picker.up", title: "Previous place in the picker", scope: "global", budget: "local", quiet: true, available: () => !!nav.picker(), local: () => nav.move(-1) });
command({ id: "picker.open", title: "Open the picked place", scope: "global", budget: "local", quiet: true, available: () => !!nav.picker(), local: (i) => void nav.choose(i == null ? undefined : +i) });
command({ id: "picker.close", title: "Close the picker", scope: "global", budget: "local", quiet: true, available: () => !!nav.picker(), local: () => nav.close() });
