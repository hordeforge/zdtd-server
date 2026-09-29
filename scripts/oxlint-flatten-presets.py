"""Flatten @rikalabs/oxlint-standards presets into one oxlint config.

oxlint rejects a config whose `extends` chain names a builtin rule it does not
implement, and the upstream presets name a few the pinned oxlint lacks. This
walks the chain, merges plugins/categories/rules in extends order (later wins),
drops builtin rules missing from `oxlint --rules -f json` (reported on stderr),
and writes the result for `.oxlintrc.jsonc` to extend. JS-plugin rules
(`@rikalabs/*`) are kept: oxlint validates those against the loaded plugin.
"""

import argparse
import json
import sys
from pathlib import Path

BUILTIN_PLUGINS = frozenset(
    {
        "eslint",
        "typescript",
        "import",
        "promise",
        "unicorn",
        "oxc",
        "react",
        "react-perf",
        "jsx-a11y",
        "nextjs",
        "node",
        "vitest",
        "jest",
        "jsdoc",
        "vue",
    }
)


def merge(path: Path, out: dict[str, dict[str, object]], seen: set[Path]) -> None:
    path = path.resolve()
    if path in seen:
        return
    seen.add(path)
    preset = json.loads(path.read_text(encoding="utf-8"))
    for parent in preset.get("extends", []):
        merge(path.parent / parent, out, seen)
    for plugin in preset.get("plugins", []):
        out["plugins"][plugin] = True
    out["categories"].update(preset.get("categories", {}))
    out["rules"].update(preset.get("rules", {}))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("rules_json", type=Path, help="output of `oxlint --rules -f json`")
    parser.add_argument("out_json", type=Path, help="flattened config to write")
    parser.add_argument("presets", type=Path, nargs="+", help="preset files, in extends order")
    args = parser.parse_args()
    # oxlint lists scopes with underscores (jsx_a11y); configs use hyphens.
    rules_list = json.loads(args.rules_json.read_text(encoding="utf-8"))
    known = {f"{r['scope'].replace('_', '-')}/{r['value']}" for r in rules_list}
    merged: dict[str, dict[str, object]] = {"plugins": {}, "categories": {}, "rules": {}}
    seen: set[Path] = set()
    for preset in args.presets:
        merge(preset, merged, seen)
    rules: dict[str, object] = {}
    for name, setting in merged["rules"].items():
        scope = name.split("/", 1)[0] if "/" in name else "eslint"
        full = name if "/" in name else f"eslint/{name}"
        if scope in BUILTIN_PLUGINS and full not in known:
            print(f"zdtd: oxlint presets: dropping {name} (not implemented by this oxlint)", file=sys.stderr)
            continue
        rules[name] = setting
    config = {"plugins": list(merged["plugins"]), "categories": merged["categories"], "rules": rules}
    args.out_json.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
