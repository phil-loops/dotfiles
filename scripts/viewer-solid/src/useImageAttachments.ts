import { createSignal } from "solid-js";
import { createStore, produce } from "solid-js/store";

export type Att = { id: number; name: string; path: string; url: string; uploading: boolean };

// Image attachments for a chat message: drag/drop or paste → upload to /chat-attach, track
// per-item upload state, revoke object URLs on drop. Fully self-contained.
export function useImageAttachments() {
  const [atts, setAtts] = createStore<Att[]>([]);
  const [dragOver, setDragOver] = createSignal(false);
  let attSeq = 0;
  const toB64 = (buf: ArrayBuffer): string => {
    const bytes = new Uint8Array(buf);
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return btoa(bin);
  };
  const dropAtt = (id: number) => {
    const it = atts.find((a) => a.id === id);
    if (it) {
      URL.revokeObjectURL(it.url);
    }
    setAtts(produce((list) => {
      const i = list.findIndex((a) => a.id === id);
      if (i >= 0) {
        list.splice(i, 1);
      }
    }));
  };
  const addImage = async (file: File) => {
    const id = ++attSeq;
    const name = file.name || "pasted.png";
    setAtts(produce((list) => {
      list.push({ id, name, path: "", url: URL.createObjectURL(file), uploading: true });
    }));
    try {
      const r = await fetch("/chat-attach", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, dataB64: toB64(await file.arrayBuffer()) }),
      }).then((res) => res.json());
      if (r.ok && r.path) {
        setAtts(produce((list) => {
          const it = list.find((a) => a.id === id);
          if (it) {
            it.path = r.path;
            it.uploading = false;
          }
        }));
      } else {
        dropAtt(id);
      }
    } catch {
      dropAtt(id);
    }
  };
  const takeImages = (files: FileList | null | undefined): boolean => {
    let took = false;
    for (const f of files ?? []) {
      if (f.type.startsWith("image/")) {
        void addImage(f);
        took = true;
      }
    }
    return took;
  };
  return { atts, setAtts, dragOver, setDragOver, dropAtt, addImage, takeImages };
}
