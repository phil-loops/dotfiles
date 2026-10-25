"""Phil's key overrides for the viewer: ~/.dotfiles/canopy/keys.toml, command id → key(s)."""
import os
import tomllib

PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "canopy", "keys.toml")


def load():
    """{"keys": {id: [key, …]}, "errors": [...]} — a bad file binds nothing and says why."""
    try:
        with open(PATH, "rb") as f:
            raw = tomllib.load(f)
    except FileNotFoundError:
        return {"keys": {}, "errors": []}
    except (OSError, tomllib.TOMLDecodeError) as e:
        return {"keys": {}, "errors": [f"keys.toml: {e}"]}
    keys, errors = {}, []
    for cid, v in raw.items():
        v = [v] if isinstance(v, str) else v
        if isinstance(v, list) and all(isinstance(k, str) for k in v):
            keys[cid] = [k for k in v if k]
        else:
            errors.append(f"{cid}: wants a key or a list of keys")
    return {"keys": keys, "errors": errors}
